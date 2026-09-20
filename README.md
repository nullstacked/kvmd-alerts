# kvmd-alerts

Bar across the top of the [PiKVM](https://pikvm.org/) video when the target machine plays a
notification sound: red "🔔 Sound detected: possible alert at HH:MM" for a message ping
(Teams / Google Chat / Slack), orange "📞 Sound detected: possible call at HH:MM" for a
ringing call (since 1.4.0; the detector classifies the sound and sends `kind` "call" |
"alert" plus a ready `label`; older detectors get a plain "🔔 Sound detected"). Talking is
recognised as a meeting and does not fire.

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
rw; pacman -U kvmd-alerts-1.4.0-1-any.pkg.tar.zst; ro
```

Re-applies itself after kvmd upgrades via an ALPM PostTransaction hook.

Since 1.3 the `/alerts/` location is outside kvmd's login check (`auth_request off`) and restricted by source network instead (LAN, tailnet, the gateway proxy), with `Access-Control-Allow-Origin: *`, so the snapshot dashboard at monitor.supportandtechnology.com can subscribe to every station's stream cross-origin without cookies. The events carry only the station name and timings.
