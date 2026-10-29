-- Minimal HTTPS client for the Enphase IQ Gateway local API (firmware 7/8, owner token).
-- The gateway uses a self-signed certificate, so verification is disabled (LAN only).
local socket = require "cosock.socket"
local ssl = require "cosock.ssl"
local json = require "st.json"

local M = {}
local TIMEOUT = 25 -- production.json can take several seconds on D8 firmware

local function tls_connect(host, timeout)
  local sock, err = socket.tcp()
  if not sock then return nil, "tcp: " .. tostring(err) end
  sock:settimeout(timeout or TIMEOUT)
  local ok, cerr = sock:connect(host, 443)
  if not ok then
    sock:close()
    return nil, "connect: " .. tostring(cerr)
  end
  local tls, werr = ssl.wrap(sock, { mode = "client", protocol = "any", verify = "none", options = "all" })
  if not tls then
    sock:close()
    return nil, "tls wrap: " .. tostring(werr)
  end
  local hs, herr = tls:dohandshake()
  if not hs then
    tls:close()
    return nil, "tls handshake: " .. tostring(herr)
  end
  return tls
end

--- One HTTPS GET. Returns status, body, headers  or nil, err.
function M.get(host, path, token, cookie)
  local sock, err = tls_connect(host)
  if not sock then return nil, err end
  local lines = {
    "GET " .. path .. " HTTP/1.1",
    "Host: " .. host,
    "User-Agent: smartthings-edge-enphase-local",
    "Accept: application/json",
    "Connection: close",
  }
  if token and token ~= "" then lines[#lines + 1] = "Authorization: Bearer " .. token end
  if cookie then lines[#lines + 1] = "Cookie: " .. cookie end
  local sent, serr = sock:send(table.concat(lines, "\r\n") .. "\r\n\r\n")
  if not sent then sock:close(); return nil, "send: " .. tostring(serr) end

  local function fail(msg) sock:close(); return nil, msg end
  local line, rerr = sock:receive("*l")
  if not line then return fail("receive status: " .. tostring(rerr)) end
  local status = tonumber(line:match("^HTTP/%d%.?%d?%s+(%d+)"))
  if not status then return fail("bad status line") end
  local headers, cookies = {}, {}
  while true do
    line, rerr = sock:receive("*l")
    if not line then return fail("receive headers: " .. tostring(rerr)) end
    if line == "" then break end
    local k, v = line:match("^([^:]+):%s*(.-)%s*$")
    if k then
      k = k:lower()
      headers[k] = v
      if k == "set-cookie" then cookies[#cookies + 1] = v:match("^([^;]+)") end
    end
  end
  headers.cookies = cookies
  local parts = {}
  if (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
    while true do
      line, rerr = sock:receive("*l")
      if not line then return fail("receive chunk size: " .. tostring(rerr)) end
      local size = tonumber(line:match("^%s*(%x+)"), 16)
      if not size then return fail("bad chunk size") end
      if size == 0 then break end
      local data, cerr = sock:receive(size)
      if not data then return fail("receive chunk: " .. tostring(cerr)) end
      parts[#parts + 1] = data
      sock:receive("*l")
    end
  elseif headers["content-length"] then
    local len = tonumber(headers["content-length"]) or 0
    if len > 0 then
      local data, cerr = sock:receive(len)
      if not data then return fail("receive body: " .. tostring(cerr)) end
      parts[#parts + 1] = data
    end
  else
    local data, _, partial = sock:receive("*a")
    parts[#parts + 1] = data or partial or ""
  end
  sock:close()
  return status, table.concat(parts), headers
end

--- Client with session cookie handling.
local Client = {}
Client.__index = Client

function M.new(host, token) return setmetatable({ host = host, token = token }, Client) end

function Client:auth()
  local status, body, headers = M.get(self.host, "/auth/check_jwt", self.token)
  if not status then return nil, body end
  if status ~= 200 or not tostring(body):find("Valid token", 1, true) then
    return nil, "token rejected (HTTP " .. tostring(status) .. ")"
  end
  self.cookie = (#headers.cookies > 0) and table.concat(headers.cookies, "; ") or nil
  return true
end

--- GET JSON; re-authenticates once on 401.
function Client:json(path)
  for attempt = 1, 2 do
    if not self.cookie and attempt == 1 then
      local ok, err = self:auth()
      if not ok then return nil, err end
    end
    local status, body = M.get(self.host, path, self.token, self.cookie)
    if not status then return nil, body end
    if status == 401 and attempt == 1 then
      self.cookie = nil
      local ok, err = self:auth()
      if not ok then return nil, err end
    elseif status ~= 200 then
      return nil, "HTTP " .. status .. " on " .. path, status
    else
      local ok, data = pcall(json.decode, body)
      if not ok or type(data) ~= "table" then return nil, "invalid JSON on " .. path end
      return data
    end
  end
  return nil, "unauthorized"
end

return M
