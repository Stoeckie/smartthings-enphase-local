-- Turn IQ Gateway JSON into readings for SmartThings.
local M = {}

local function find(list, measurement)
  for _, e in ipairs(list or {}) do
    if e.type == "eim" and e.measurementType == measurement and (tonumber(e.activeCount) or 1) > 0 then
      return e
    end
  end
end

--- production.json?details=1 -> { solar = {w, wh_lifetime, wh_today}, consumption = {...}, grid = {w} }
--- grid.w: positive = import from the grid, negative = export.
function M.from_production(p)
  local out = {}
  local prod = find(p.production, "production")
  if prod then
    out.solar = { w = tonumber(prod.wNow), wh_lifetime = tonumber(prod.whLifetime), wh_today = tonumber(prod.whToday) }
  else
    for _, e in ipairs(p.production or {}) do
      if e.type == "inverters" then
        out.solar = { w = tonumber(e.wNow), wh_lifetime = tonumber(e.whLifetime) }
      end
    end
  end
  local total = find(p.consumption, "total-consumption")
  if total then
    out.consumption = { w = tonumber(total.wNow), wh_lifetime = tonumber(total.whLifetime),
                        wh_today = tonumber(total.whToday) }
  end
  local net = find(p.consumption, "net-consumption")
  if net then out.grid = { w = tonumber(net.wNow) } end
  if out.solar and out.solar.w and out.solar.w < 0 then out.solar.w = 0 end -- night-time inverter draw
  return out
end

--- /ivp/meters (config) + /ivp/meters/readings -> same shape as from_production. Fast (<1 s), unlike
--- production.json which can take 10-30 s on D8 firmware (especially at night).
function M.from_meters(meters, readings)
  local kind = {}
  for _, m in ipairs(meters or {}) do
    if m.state == "enabled" then kind[tostring(m.eid)] = m.measurementType end
  end
  local prod, net
  for _, r in ipairs(readings or {}) do
    local k = kind[tostring(r.eid)]
    if k == "production" then prod = r elseif k == "net-consumption" then net = r end
  end
  if not prod and not net then return nil end
  local out = {}
  if prod then
    local w = tonumber(prod.activePower) or 0
    if w < 0 then w = 0 end
    out.solar = { w = w, wh_lifetime = (tonumber(prod.actEnergyDlvd) or 0) }
  end
  if net then out.grid = { w = tonumber(net.activePower) } end
  if prod and net then
    local w = (tonumber(prod.activePower) or 0) + (tonumber(net.activePower) or 0)
    local wh = (tonumber(prod.actEnergyDlvd) or 0) - (tonumber(prod.actEnergyRcvd) or 0)
             + (tonumber(net.actEnergyDlvd) or 0) - (tonumber(net.actEnergyRcvd) or 0)
    out.consumption = { w = math.max(0, w), wh_lifetime = wh }
  end
  return out
end

--- ensemble power + secctrl -> { soc, w }  ; w: positive = discharging (into the home), negative = charging
function M.battery(power, secctrl)
  local b = {}
  if type(secctrl) == "table" then b.soc = tonumber(secctrl.agg_soc or secctrl.ENC_agg_soc) end
  local devs = type(power) == "table" and (power["devices:"] or power.devices) or nil
  if type(devs) == "table" then
    local mw, socs, n = 0, 0, 0
    for _, d in ipairs(devs) do
      mw = mw + (tonumber(d.real_power_mw) or 0)
      if d.soc then socs = socs + tonumber(d.soc); n = n + 1 end
    end
    b.w = mw / 1000
    if not b.soc and n > 0 then b.soc = socs / n end
  end
  if b.soc == nil and b.w == nil then return nil end
  return b
end

return M
