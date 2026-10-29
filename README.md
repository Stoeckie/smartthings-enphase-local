# Enphase IQ Gateway (local) — SmartThings Edge driver

Solar, consumption, grid and **IQ Battery** data from an **Enphase IQ Gateway / Envoy** (firmware 7 and 8) in SmartThings, read locally over the gateway's HTTPS API. No cloud polling, no bridge computer.

## What you get

One gateway device with child devices:

| Device | Values |
|---|---|
| Zonnepanelen (solar) | power (W), lifetime energy (kWh) |
| Verbruik (consumption) | power, lifetime energy (needs consumption CTs) |
| Net (grid) | power: positive = import, negative = export |
| Thuisbatterij (battery) | state of charge (%), power (positive = discharging) |

Default poll every 30 s. Rename the devices as you like.

## Requirements

* SmartThings hub with Edge, on the same network as the IQ Gateway
* An **owner token** for the gateway (firmware 7/8 need one)

### Get the token

1. Go to **entrez.enphaseenergy.com** and log in with your Enphase (Enlighten) owner account.
2. Choose your system and your gateway, and click **Generate Access Token**.
3. The token is valid for 12 months. Renew it the same way.

## Install

1. Enroll your hub in the channel: https://bestow-regional.api.smartthings.com/invite/qWjBdybRNG2y (Stoeckie Edge Drivers) and install **Enphase IQ Gateway (local)**.
2. SmartThings app: **Add device → Scan nearby**. An "Enphase IQ Gateway" device appears.
3. Enter the token on the **settings page on the hub**. The SmartThings app cuts text fields at 250 characters and tokens are longer, so the driver serves a small page instead:
   * the address is in the hub log: `[enphase] settings page: http://<hub-ip>:<port>/`
   * the page is open while no token is set, and for 10 minutes after pressing Refresh on the gateway device
   * IP can stay empty (found via mDNS / envoy.local)
4. Within a poll the child devices appear.

## How it works

* Auth: `GET /auth/check_jwt` with the token, then the session cookie.
* Power and energy: `/ivp/meters` + `/ivp/meters/readings` (fast, under 1 s). On D8 firmware `production.json` can take 10 to 30 s, at night especially, so it is only used as a fallback for systems without CT meters (at most every 5 minutes).
* Battery: `/ivp/ensemble/secctrl` (`agg_soc`) and `/ivp/ensemble/power`, every 4th poll.
* Polls never overlap; the gateway handles only a few connections at a time.
* TLS certificate verification is off: the gateway uses a self-signed certificate (LAN only).

## Privacy

The token is stored on the hub only (persistent device field). Nothing secret is in this code or the package.

## Development

```
smartthings edge:drivers:package .
pip install lupa pytest && python -m pytest tests
```

## License

Apache 2.0, see LICENSE. Not affiliated with Enphase Energy or Samsung SmartThings.
