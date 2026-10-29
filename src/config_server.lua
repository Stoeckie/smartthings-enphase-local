-- Small settings page on the hub to enter the IQ Gateway IP and owner token (too long for most app fields).
-- Values are stored on the hub only (persistent device fields), never in the driver package.
local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"

local M = {}

local function url_decode(s)
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parse_form(body)
  local out = {}
  for pair in (body or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    if k then out[url_decode(k)] = url_decode(v or "") end
  end
  return out
end

local function esc(s)
  return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
                                               ['"'] = "&quot;", ["'"] = "&#39;" }))
end

local function page(title, inner)
  return [[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Enphase IQ Gateway (local)</title>
<style>body{font-family:system-ui,sans-serif;max-width:520px;margin:32px auto;padding:0 16px;color:#222}
h1{font-size:1.3em}label{display:block;margin-top:14px;font-weight:600}
input,textarea{width:100%;box-sizing:border-box;padding:8px;font-size:1em;margin-top:4px}
textarea{height:120px;font-family:ui-monospace,monospace;font-size:.85em}
button{margin-top:18px;padding:10px 18px;font-size:1em}.note{color:#666;font-size:.9em}
.ok{color:#0a7d2c}.err{color:#b00020}</style></head><body><h1>]] .. esc(title) .. "</h1>" .. inner .. "</body></html>"
end

local function form_page(status)
  return page("Enphase IQ Gateway (local)", [[
<p class="note">Status: ]] .. esc(status.text) .. [[</p>
<form method="post" action="/save">
<label for="host">Gateway IP address</label>
<input id="host" name="host" value="]] .. esc(status.host) .. [[" placeholder="auto">
<label for="token">Owner token</label>
<textarea id="token" name="token" autocomplete="off" placeholder="paste the token from entrez.enphaseenergy.com" required></textarea>
<p class="note">Get the token at entrez.enphaseenergy.com with your Enphase owner account (valid 12 months).
It is stored on your SmartThings hub only and is never shown again.</p>
<button type="submit">Save and connect</button></form>]])
end

local function respond(client, code, body)
  local reason = ({ [200] = "OK", [400] = "Bad Request", [404] = "Not Found" })[code] or "OK"
  client:send(string.format("HTTP/1.1 %d %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\n" ..
    "Cache-Control: no-store\r\nConnection: close\r\n\r\n", code, reason, #body) .. body)
end

local function read_request(client)
  client:settimeout(5)
  local line, err = client:receive("*l")
  if not line then return nil, err end
  if #line > 2048 then return nil, "request line too long" end
  local method, path = line:match("^(%u+)%s+(%S+)")
  local headers = {}
  for _ = 1, 41 do
    local h = client:receive("*l")
    if not h or h == "" then break end
    if #h > 4096 then return nil, "header too long" end
    local k, v = h:match("^([^:]+):%s*(.-)%s*$")
    if k then headers[k:lower()] = v end
  end
  local body = ""
  local len = tonumber(headers["content-length"] or "0") or 0
  if len > 0 and len < 16384 then body = client:receive(len) or "" end
  return { method = method, path = path, body = body }
end

function M.valid_host(h) return h == "" or (#h <= 253 and h:match("^[%w%.%-]+$") ~= nil) end
function M.valid_token(t) return #t >= 100 and #t <= 4096 and t:match("^[%w%-_%.]+$") ~= nil end

--- opts.get_status() -> {text, host}; opts.on_save(host, token). Returns {port, stop()} or nil, err.
function M.start(opts)
  local server, err = socket.tcp()
  if not server then return nil, err end
  local ok, berr = server:bind("*", 0)
  if not ok then return nil, "bind: " .. tostring(berr) end
  server:listen(4)
  server:settimeout(2)
  local _, port = server:getsockname()
  local srv = { port = port, running = true }
  function srv.stop() srv.running = false end
  cosock.spawn(function()
    while srv.running do
      local client = server:accept()
      if client and not srv.running then
        client:close()
      elseif client then
        cosock.spawn(function()
          local okh, herr = pcall(function()
            local req = read_request(client)
            if not req then return end
            if req.method == "GET" and (req.path == "/" or req.path:match("^/%?")) then
              respond(client, 200, form_page(opts.get_status()))
            elseif req.method == "POST" and req.path == "/save" then
              local form = parse_form(req.body)
              local host = (form.host or ""):gsub("%s", ""):gsub("^https?://", ""):gsub("/.*$", "")
              if host == "auto" then host = "" end
              local token = (form.token or ""):gsub("%s", "")
              if not M.valid_host(host) or not M.valid_token(token) then
                respond(client, 400, page("Not saved", '<p class="err">Please paste a valid token (and IP or leave it empty).</p><p><a href="/">Back</a></p>'))
              else
                opts.on_save(host, token)
                respond(client, 200, page("Saved", '<p class="ok">Saved. The driver is connecting to the gateway.</p>' ..
                  '<p class="note">This page closes itself shortly. Press Refresh on the Enphase IQ Gateway device to open it again for 10 minutes.</p>'))
              end
            else
              respond(client, 404, page("Not found", '<p><a href="/">Settings</a></p>'))
            end
          end)
          if not okh then log.warn("[enphase] settings page error: " .. tostring(herr)) end
          client:close()
        end, "enphase settings client")
      end
    end
    server:close()
  end, "enphase settings server")
  return srv
end

M._parse_form = parse_form
return M
