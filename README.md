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

**Battery history graph** (setting on Thuisbatterij): SmartThings draws no graph for battery %. Choose *Humidity (%)* to get the state of charge also as a humidity reading with a graph (the device then also counts as a humidity sensor), or *Power (W)* for an extra part "Battery %" with 1 % = 1 W (can show up in energy overviews). Default off; the driver switches the device to the matching profile by itself.

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
   * for security the page is open for at most 15 minutes: after the driver starts without a token, and after pressing Refresh on the gateway device; about a minute after saving it closes
   * IP can stay empty (found via mDNS / envoy.local)
4. Within a poll the child devices appear.

## How it works

* Auth: `GET /auth/check_jwt` with the token, then the session cookie.
* Power and energy: `/ivp/meters` + `/ivp/meters/readings` (fast, under 1 s). On D8 firmware `production.json` can take 10 to 30 s, at night especially, so it is only used as a fallback for systems without CT meters (at most every 5 minutes).
* Battery: `/ivp/ensemble/secctrl` (`agg_soc`) and `/ivp/ensemble/power`, every 4th poll.
* Polls never overlap; the gateway handles only a few connections at a time.
* TLS certificate verification is off: the gateway uses a self-signed certificate (LAN only).

## Offline notification

SmartThings has no routine trigger for "device offline". The Enphase gateway device therefore has a **Connection** status (Connected or Offline). Make a routine to get a message:

If Enphase gateway device > Connection is Offline, then send a notification to members.

Short drops (a reconnect or one missed poll) are ignored: Connection only turns Offline after 2 minutes without a connection.

Every drop is remembered. When the connection is back, the device shows **Last drop**: time (UTC), how long it lasted and the reason (for example "session closed" or "timeout"). Older drops are in the device history.

## Privacy

The token is stored on the hub only (persistent device field). Nothing secret is in this code or the package.

## Development

```
smartthings edge:drivers:package .
pip install lupa pytest && python -m pytest tests
```

## License

Apache 2.0, see LICENSE. Not affiliated with Enphase Energy or Samsung SmartThings.
