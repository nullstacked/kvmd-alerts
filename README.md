# kvmd-alerts

Red "🔔 Sound detected at HH:MM" bar across the top of the [PiKVM](https://pikvm.org/) video
when the target machine goes from a long quiet stretch (60 s) to any sound — a Teams / Google
Chat / Slack ping, an incoming-call ring, or someone starting to talk. It fires at the onset
and re-arms only after another 60 s of quiet, so a meeting fires once when it starts.

The detection runs on the audio hub that already taps each station's microphone
(`pikvm-alert-detect`, in the infra repo). This package only carries the UI side:

- `alerts.css` and a banner `div` in `index.html`;
- a marker-delimited block in `session.js` that subscribes to `/alerts/` with an
  `EventSource` and shows the banner per event until you click it, 60 s pass, or
  (since 1.3.5) you move the mouse, which shortens it to ~8 s since it appeared — the tab title gets a bell meanwhile;
- an auth-gated `location /alerts/` in kvmd-nginx that reverse-proxies the SSE stream
  from `linux:8040/events/<station>` (`X-Accel-Buffering: no`, no proxy buffering).

Station name comes from `/etc/kvmd/listen.conf` (`STATION=<name>`), shared with
[kvmd-listen](https://github.com/nullstacked/kvmd-listen). Inert without it.

```bash
rw; pacman -U kvmd-alerts-1.3.0-1-any.pkg.tar.zst; ro
```

Re-applies itself after kvmd upgrades via an ALPM PostTransaction hook.

Since 1.3 the `/alerts/` location is outside kvmd's login check (`auth_request off`) and restricted by source network instead (LAN, tailnet, the gateway proxy), with `Access-Control-Allow-Origin: *`, so the snapshot dashboard at monitor.supportandtechnology.com can subscribe to every station's stream cross-origin without cookies. The events carry only the station name and timings.
