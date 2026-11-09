import json
from run_lua import runtime, req
from run_lua import SRC as _S
SRC = str(_S)
PROD = {"production": [{"type": "inverters", "activeCount": 20, "wNow": 1500, "whLifetime": 9000000},
                       {"type": "eim", "activeCount": 1, "measurementType": "production", "wNow": 1523.4, "whLifetime": 9100000, "whToday": 4200}],
        "consumption": [{"type": "eim", "activeCount": 1, "measurementType": "total-consumption", "wNow": 800, "whLifetime": 15000000, "whToday": 6000},
                        {"type": "eim", "activeCount": 1, "measurementType": "net-consumption", "wNow": -723.4, "whLifetime": 1}],
        "storage": [{"type": "acb", "activeCount": 0, "wNow": 0}]}
POWER = {"devices:": [{"serial_num": "1", "real_power_mw": 1200000, "soc": 80}, {"serial_num": "2", "real_power_mw": 800000, "soc": 84}]}
SEC = {"agg_soc": 82, "Max_energy": 10000}

def test_model():
    lua = runtime()
    j = req(lua, "st.json"); m = req(lua, "envoy_model")
    r = m.from_production(j.decode(json.dumps(PROD).encode()))
    assert r[b"solar"][b"w"] == 1523.4 and r[b"consumption"][b"w"] == 800 and r[b"grid"][b"w"] == -723.4
    b = m.battery(j.decode(json.dumps(POWER).encode()), j.decode(json.dumps(SEC).encode()))
    assert b[b"soc"] == 82 and b[b"w"] == 2000
    # no CTs: falls back to inverters, no consumption/grid
    noct = dict(PROD); noct["production"] = [PROD["production"][0], dict(PROD["production"][1], activeCount=0)]
    noct["consumption"] = [dict(c, activeCount=0) for c in PROD["consumption"]]
    r2 = m.from_production(j.decode(json.dumps(noct).encode()))
    assert r2[b"solar"][b"w"] == 1500 and r2[b"consumption"] is None and r2[b"grid"] is None
    assert m.battery(None, None) is None

def test_form():
    lua = runtime()
    lua.execute(b'package.loaded["cosock"] = {}; package.loaded["cosock.socket"] = {}; package.loaded["log"] = {}')
    cs = req(lua, "config_server")
    f = cs._parse_form(b"host=192.168.2.20&token=eyJ.abc%2Bdef_-.x")
    assert f[b"host"] == b"192.168.2.20" and f[b"token"] == b"eyJ.abc+def_-.x"
    assert cs.valid_token(b"eyJ" + b"a" * 300 + b".b-c_d")
    assert not cs.valid_token(b"short")

METERS = [{"eid": 704643328, "state": "enabled", "measurementType": "production"},
          {"eid": 704643584, "state": "enabled", "measurementType": "net-consumption"},
          {"eid": 704643840, "state": "disabled", "measurementType": "storage"}]
READ = [{"eid": 704643328, "activePower": 0.0, "actEnergyDlvd": 1646393.823, "actEnergyRcvd": 5001.198},
        {"eid": 704643584, "activePower": 3238.244, "actEnergyDlvd": 2385317.725, "actEnergyRcvd": 1399482.52},
        {"eid": 704643840, "activePower": 0.0, "actEnergyDlvd": 0.0, "actEnergyRcvd": 0.0}]

def test_meters():
    lua = runtime()
    j = req(lua, "st.json"); m = req(lua, "envoy_model")
    r = m.from_meters(j.decode(json.dumps(METERS).encode()), j.decode(json.dumps(READ).encode()))
    assert r[b"solar"][b"w"] == 0 and r[b"grid"][b"w"] == 3238.244
    assert abs(r[b"consumption"][b"w"] - 3238.244) < 1e-6
    assert abs(r[b"consumption"][b"wh_lifetime"] - 2627227.83) < 1


def test_settings_page_secret_path():
    """The settings page only answers under its secret path; wrong paths count and close it after 30."""
    lua = runtime()
    lua.execute(b'''
      QUEUE = {}
      package.loaded["log"] = { warn = function() end, info = function() end }
      package.loaded["cosock"] = { spawn = function(f) local ok, e = pcall(f); if not ok and not tostring(e):find("EMPTY") then error(e) end end }
      local server = { bind = function() return true end, listen = function() end, settimeout = function() end,
                       getsockname = function() return "0.0.0.0", 4321 end, close = function() end }
      function server:accept()
        local c = table.remove(QUEUE, 1)
        if not c then error("EMPTY") end
        return c
      end
      package.loaded["cosock.socket"] = { tcp = function() return server end, gettime = os.clock }
      function CLIENT(raw)
        local pos = 1
        local c = { out = "" }
        function c:settimeout() end
        function c:receive(p)
          if p == "*l" then
            local i = raw:find("\\r\\n", pos, true)
            if not i then return nil end
            local l = raw:sub(pos, i - 1); pos = i + 2; return l
          end
          local s = raw:sub(pos, pos + p - 1); pos = pos + p; return s
        end
        function c:send(s) self.out = self.out .. s end
        function c:close() end
        QUEUE[#QUEUE + 1] = c
        return c
      end
      cs = require "config_server"
    ''')
    a, b = lua.eval(b"cs._make_secret()"), lua.eval(b"cs._make_secret()")
    assert len(a) == 24 and a != b
    token = "eyJ" + "a" * 200
    body = "host=&token=" + token
    host = "Host: 192.168.2.8:4321\r\n"
    reqs = ["GET / HTTP/1.1\r\n" + host + "\r\n",
            "POST /save HTTP/1.1\r\n%sContent-Length: %d\r\n\r\n%s" % (host, len(body), body),
            "GET /s3cr3t/ HTTP/1.1\r\n" + host + "\r\n",
            "POST /s3cr3t/save HTTP/1.1\r\n%sContent-Length: %d\r\n\r\n%s" % (host, len(body), body)]
    lua.execute(b"CL = {}; SAVED = nil")
    for r in reqs:
        lua.execute(("CL[#CL + 1] = CLIENT(%s)" % json.dumps(r)).encode())
    lua.execute(b'SRV = cs.start({ test_secret = "s3cr3t", get_status = function() return { text = "x", host = "" } end, on_save = function(h, t) SAVED = t end })')
    outs = [lua.eval(b"CL[%d].out" % (i + 1)) for i in range(len(reqs))]
    assert outs[0].startswith(b"HTTP/1.1 404") and outs[1].startswith(b"HTTP/1.1 404")
    assert outs[2].startswith(b"HTTP/1.1 200") and b'action="save"' in outs[2]
    assert outs[3].startswith(b"HTTP/1.1 200") and lua.eval(b"SAVED") == token.encode()
    assert lua.eval(b"SRV.wrong") == 2
    # 30 wrong paths close the page
    lua.execute(b"CL = {}")
    for _ in range(30):
        lua.execute(("CLIENT(%s)" % json.dumps("GET /x/ HTTP/1.1\r\n" + host + "\r\n")).encode())
    lua.execute(b'SRV = cs.start({ test_secret = "s3cr3t", get_status = function() return {} end, on_save = function() end })')
    assert lua.eval(b"SRV.running") is False


def test_deadband():
    """30 s polls: power only on >= max(25 W, 3 %) or every 5 min; energy every 5 min or on >= 0.1 kWh."""
    lua = runtime()
    m = req(lua, "envoy_model")
    T = lua.eval(b"function(v, t) return { v = v, t = t } end")
    assert m.power_due(None, 500, 0)
    assert not m.power_due(T(500, 0), 520, 30)        # 20 W < 25 W
    assert m.power_due(T(500, 0), 525, 30)
    assert not m.power_due(T(3000, 0), 3080, 30)      # 80 W < 3 % of 3000
    assert m.power_due(T(3000, 0), 3090, 30)
    assert m.power_due(T(-1200, 0), -1240, 30)        # export (negative) works the same
    assert m.power_due(T(500, 0), 501, 300)           # 5 minutes passed
    assert not m.energy_due(T(1234.56, 0), 1234.62, 30)
    assert m.energy_due(T(1234.56, 0), 1234.66, 30)
    assert m.energy_due(T(1234.56, 0), 1234.57, 300)
    # one hour of noisy 30 s polls around 2 kW: about one power event a minute or less
    sent, last = 0, None
    import random
    rnd = random.Random(1)
    for i in range(120):
        w = 2000 + rnd.randint(-40, 40)
        if m.power_due(last, w, i * 30):
            sent += 1
            last = T(w, i * 30)
    assert sent <= 60


def test_bind_failure_closes_socket():
    lua = runtime()
    lua.execute(b'''
      CLOSED = false
      package.loaded["log"] = { warn = function() end, info = function() end }
      package.loaded["cosock"] = { spawn = function() end }
      local server = { bind = function() return nil, "address in use" end, close = function() CLOSED = true end }
      package.loaded["cosock.socket"] = { tcp = function() return server end, gettime = os.clock }
      cs = require "config_server"
      R, E = cs.start({})''')
    g = lua.globals()
    assert g.R is None and b"bind" in g.E and g.CLOSED is True
