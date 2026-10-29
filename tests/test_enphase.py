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
