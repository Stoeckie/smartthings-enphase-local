-- SmartThings Edge driver: Enphase IQ Gateway (Envoy, firmware 7/8) over the local HTTPS API.
-- One gateway device, with child devices for Solar, Consumption, Grid and Battery.
-- The owner token is entered on a small settings page on the hub (or as a device setting) and stored on
-- the hub only; nothing secret lives in the code.
local Driver = require "st.driver"
local capabilities = require "st.capabilities"

-- Connection status as a capability, so routines can notify when this device loses its connection
-- (SmartThings itself has no "device offline" trigger for routines).
local conn_cap = capabilities["silvervalley08660.connectionStatus"]
local function set_conn(dev, up)
  local v = up and "online" or "offline"
  if dev:get_field("conn_status") == v then return end
  local ok = pcall(function() dev:emit_event(conn_cap.status(v)) end)
  if ok then dev:set_field("conn_status", v) end
end
local log = require "log"
local cosock = require "cosock"
local api = require "envoy_api"
local model = require "envoy_model"
local config_server = require "config_server"

local BUILD = "2026-11-01b"
local SETTINGS_OPEN_SECS = 900

local CHILDREN = {
  { key = "solar", label = "Zonnepanelen", profile = "enphase-solar" },
  { key = "consumption", label = "Verbruik", profile = "enphase-consumption" },
  { key = "grid", label = "Net", profile = "enphase-grid" },
  { key = "battery", label = "Thuisbatterij", profile = "enphase-battery" },
}

local state = {} -- parent.id -> { client, timer, server, server_until, last_ok, err }

local function is_parent(d) return d.parent_assigned_child_key == nil end

local function clean(s) return (tostring(s or ""):gsub("%s", "")) end

local function settings(parent)
  local p = parent.preferences or {}
  -- the token from the settings page wins; the app field cuts text at 250 characters
  local token = parent:get_field("token") or ""
  if token == "" then
    token = clean(p.token)
    if #token >= 250 and #token <= 255 then
      log.warn("[enphase] the token in the app settings is cut off (" .. #token .. " chars); use the settings page")
      token = ""
    elseif #token < 100 then
      token = ""
    end
  end
  local host = clean(p.ipAddress)
  if host == "" or host == "auto" then host = parent:get_field("host") or parent:get_field("ip") or "" end
  return host, token
end

local function discover_ip()
  local ok, mdns = pcall(require, "st.mdns")
  if ok then
    for _, svc in ipairs({ "_enphase-envoy._tcp", "_http._tcp" }) do
      local res = mdns.discover(svc, "local")
      for _, f in ipairs((res and res.found) or {}) do
        local name = tostring((f.service_info or {}).name or "") .. " " .. tostring((f.host_info or {}).name or "")
        local addr = (f.host_info or {}).address
        if addr and addr:match("^%d+%.%d+%.%d+%.%d+$") and (svc ~= "_http._tcp" or name:lower():find("envoy")) then
          return addr
        end
      end
    end
  end
  local okr, ip = pcall(function() return cosock.socket.dns.toip("envoy.local") end)
  if okr and ip then return ip end
end

-- battery history: SmartThings draws no graph for battery %, so optionally repeat it as a reading that has one
local GRAPH_PROFILE = { off = "enphase-battery", humidity = "enphase-battery-hum", power = "enphase-battery-pow" }

local function graph_mode(dev)
  local m = (dev.preferences or {}).batteryGraph
  return GRAPH_PROFILE[m or ""] and m or "off"
end

local function sync_graph_profile(dev)
  local want = GRAPH_PROFILE[graph_mode(dev)]
  if dev:get_field("profile") ~= want then
    dev:try_update_metadata({ profile = want })
    dev:set_field("profile", want, { persist = true })
    log.info("[enphase] battery profile -> " .. want)
  end
end

local function emit_graph(dev, soc)
  local mode = graph_mode(dev)
  local comps = dev.profile and dev.profile.components or {}
  local ok, err = pcall(function()
    if mode == "humidity" then
      dev:emit_event(capabilities.relativeHumidityMeasurement.humidity(soc))
    elseif mode == "power" and comps.graph then
      dev:emit_component_event(comps.graph, capabilities.powerMeter.power({ value = soc, unit = "W" }))
    end
  end)
  if not ok then log.warn("[enphase] battery graph: " .. tostring(err)) end
end

local function children(driver, parent)
  local out = {}
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_device_id == parent.id and d.parent_assigned_child_key then out[d.parent_assigned_child_key] = d end
  end
  return out
end

local function ensure_children(driver, parent, readings)
  local kids = children(driver, parent)
  for _, c in ipairs(CHILDREN) do
    if readings[c.key] and not kids[c.key] then
      log.info("[enphase] creating " .. c.label)
      driver:try_create_device({ type = "EDGE_CHILD", parent_device_id = parent.id, parent_assigned_child_key = c.key,
        label = c.label, profile = c.profile, manufacturer = "Enphase", model = "IQ Gateway " .. c.key,
        vendor_provided_label = c.label })
    end
  end
  return kids
end

local poll_once

local function emit(kids, r)
  local function power(dev, w)
    if dev and w then dev:emit_event(capabilities.powerMeter.power({ value = math.floor(w + 0.5), unit = "W" })) end
  end
  local function energy(dev, wh)
    if dev and wh then dev:emit_event(capabilities.energyMeter.energy({ value = math.floor(wh / 10 + 0.5) / 100, unit = "kWh" })) end
  end
  if r.solar then power(kids.solar, r.solar.w); energy(kids.solar, r.solar.wh_lifetime) end
  if r.consumption then power(kids.consumption, r.consumption.w); energy(kids.consumption, r.consumption.wh_lifetime) end
  if r.grid then power(kids.grid, r.grid.w) end
  if r.battery and kids.battery then
    if r.battery.soc then
      local soc = math.floor(r.battery.soc + 0.5)
      kids.battery:emit_event(capabilities.battery.battery(soc))
      emit_graph(kids.battery, soc)
    end
    power(kids.battery, r.battery.w)
  end
end

local function poll(driver, parent)
  local st = state[parent.id]
  if not st or st.busy then return end -- never overlap: the gateway handles few connections at a time
  st.busy = true
  local ok, err = pcall(function() return poll_once(driver, parent, st) end)
  st.busy = false
  if not ok then log.error("[enphase] poll error: " .. tostring(err)) end
end

poll_once = function(driver, parent, st)
  local host, token = settings(parent)
  if token == "" then
    st.err = "no token yet"
    return
  end
  if host == "" then
    host = discover_ip()
    if host then
      parent:set_field("ip", host, { persist = true })
      log.info("[enphase] gateway found at " .. host)
    else
      st.err = "gateway not found (set the IP)"
      log.warn("[enphase] " .. st.err)
      set_conn(parent, false); parent:offline()
      return
    end
  end
  if not st.client or st.client.host ~= host or st.client.token ~= token then st.client = api.new(host, token) end
  local r, err
  if not st.meters then
    local m = st.client:json("/ivp/meters")
    if type(m) == "table" and #m > 0 then st.meters = m end
  end
  if st.meters then
    local readings
    readings, err = st.client:json("/ivp/meters/readings")
    if readings then r = model.from_meters(st.meters, readings) end
  end
  if not r then -- no CT meters: production.json (slow) at most every 5 minutes
    if (os.time() - (st.last_prod or 0)) < 300 and st.last_ok then return end
    st.last_prod = os.time()
    local prod
    prod, err = st.client:json("/production.json?details=1")
    if prod then r = model.from_production(prod) end
  end
  if not r then
    st.err = err
    log.warn("[enphase] " .. tostring(err))
    set_conn(parent, false); parent:offline()
    for _, k in pairs(children(driver, parent)) do k:offline() end
    return
  end
  -- battery data changes slowly: every 4th poll
  st.n = (st.n or 0) + 1
  if st.n % 4 == 1 or not st.battery then
    local power = st.client:json("/ivp/ensemble/power")
    local secctrl = st.client:json("/ivp/ensemble/secctrl")
    st.battery = model.battery(power, secctrl) or st.battery
  end
  r.battery = st.battery
  st.err, st.last_ok = nil, os.time()
  parent:online(); set_conn(parent, true)
  local kids = ensure_children(driver, parent, r)
  for _, k in pairs(kids) do k:online() end
  emit(kids, r)
end

local function schedule(driver, parent)
  local st = state[parent.id]
  if st.timer then parent.thread:cancel_timer(st.timer) end
  local interval = tonumber((parent.preferences or {}).pollInterval) or 15
  st.timer = parent.thread:call_on_schedule(interval, function() poll(driver, parent) end, "enphase-poll")
  parent.thread:call_with_delay(2, function() poll(driver, parent) end)
end

-- settings page: never open longer than SETTINGS_OPEN_SECS (after a start without token, or after Refresh)
local function check_settings(parent)
  local st = state[parent.id]
  if not (st and st.server) then return end
  if os.time() >= (st.server_until or 0) then
    st.server.stop()
    st.server = nil
    log.info("[enphase] settings page closed. Press Refresh on the gateway device to open it for 15 minutes")
  else
    parent.thread:call_with_delay(30, function() check_settings(parent) end)
  end
end

local function open_settings(driver, parent)
  local st = state[parent.id]
  st.server_until = os.time() + SETTINGS_OPEN_SECS
  if st.server and st.server.running then return end
  local srv, err = config_server.start({
    get_status = function()
      local host = settings(parent)
      local text = st.err and ("not connected: " .. st.err) or (st.last_ok and "connected" or "waiting")
      return { text = text, host = host }
    end,
    on_save = function(host, token)
      parent:set_field("host", host ~= "" and host or nil, { persist = true })
      parent:set_field("token", token, { persist = true })
      st.client = nil
      log.info("[enphase] settings saved")
      parent.thread:call_with_delay(1, function() poll(driver, parent) end)
      -- close soon after a save instead of waiting for the full window
      st.server_until = math.min(st.server_until or 0, os.time() + 60)
    end,
  })
  if not srv then
    log.error("[enphase] settings page failed: " .. tostring(err))
    return
  end
  st.server = srv
  local hub_ip = driver.environment_info and driver.environment_info.hub_ipv4 or "<hub-ip>"
  log.info(string.format("[enphase] settings page: http://%s:%d/ (open for 15 minutes)", hub_ip, srv.port))
  parent.thread:call_with_delay(30, function() check_settings(parent) end)
end

local function handle_refresh(driver, device)
  local parent = is_parent(device) and device or device:get_parent_device()
  if not parent then return end
  if is_parent(device) then open_settings(driver, parent) end
  poll(driver, parent)
end

local function device_init(driver, device)
  if not is_parent(device) then
    if device.parent_assigned_child_key == "battery" then sync_graph_profile(device) end
    return
  end
  state[device.id] = state[device.id] or {}
  schedule(driver, device)
  local _, token = settings(device)
  if token == "" then
    open_settings(driver, device)
  end
end

local function info_changed(driver, device)
  if is_parent(device) then
    state[device.id].client = nil
    schedule(driver, device)
  elseif device.parent_assigned_child_key == "battery" then
    sync_graph_profile(device)
    local parent = device:get_parent_device()
    local st = parent and state[parent.id]
    if st then st.n = 0 end -- read the battery again at the next poll
  end
end

local function device_removed(driver, device)
  local st = state[device.id]
  if st then
    if st.timer then device.thread:cancel_timer(st.timer) end
    if st.server then st.server.stop() end
  end
  state[device.id] = nil
end

local function discovery(driver, opts, should_continue)
  for _, d in ipairs(driver:get_devices()) do
    if is_parent(d) then return end -- one gateway is enough
  end
  local ip = discover_ip()
  log.info("[enphase] discovery: gateway " .. tostring(ip or "not found, create device anyway"))
  driver:try_create_device({ type = "LAN", device_network_id = "enphase-iq-gateway", label = "Enphase IQ Gateway",
    profile = "enphase-gateway", manufacturer = "Enphase", model = "IQ Gateway", vendor_provided_label = "Enphase IQ Gateway" })
end

local driver = Driver("enphase-iq-gateway-local", {
  discovery = discovery,
  lifecycle_handlers = { init = device_init, added = device_init, infoChanged = info_changed, removed = device_removed },
  capability_handlers = {
    [capabilities.refresh.ID] = { [capabilities.refresh.commands.refresh.NAME] = handle_refresh },
  },
})

log.info("[enphase] Enphase IQ Gateway (local) driver starting, build " .. BUILD)
driver:run()
