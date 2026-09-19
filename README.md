# kvmd-alerts

Big red banner across the top of the [PiKVM](https://pikvm.org/) video when the target
machine plays an **isolated notification sound** — a Teams or Google Chat ping, a Meet or
Teams incoming-call ring — after a long quiet stretch. Meetings and speech never trigger it.

The detection runs on the audio hub that already taps each station's microphone
(`pikvm-alert-detect`: a long quiet period, a short burst, quiet again; tonality
tie-breaker). This package only carries the UI side:

- `alerts.css` and a banner `div` in `index.html`;
- a marker-delimited block in `session.js` that subscribes to `/alerts/` with an
  `EventSource` and shows the banner per event until you click it, move the mouse more than ~200 px,
  or 60 s pass (the tab title gets a bell meanwhile);
- an auth-gated `location /alerts/` in kvmd-nginx that reverse-proxies the SSE stream
  from `linux:8040/events/<station>` (`X-Accel-Buffering: no`, no proxy buffering).

Station name comes from `/etc/kvmd/listen.conf` (`STATION=<name>`), shared with
[kvmd-listen](https://github.com/nullstacked/kvmd-listen). Inert without it.

```bash
rw; pacman -U kvmd-alerts-1.2.0-1-any.pkg.tar.zst; ro
```

Re-applies itself after kvmd upgrades via an ALPM PostTransaction hook.

Since 1.2 the `/alerts/` location also sends CORS headers for `https://monitor.supportandtechnology.com`, so the snapshot dashboard can subscribe to every station's stream cross-origin (with credentials).
