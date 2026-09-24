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
rw; pacman -U kvmd-alerts-1.6.1-1-any.pkg.tar.zst; ro
```

**Name banner (1.5.0, redesigned 1.6.x).** When someone on the call says your name, a slim
**one-line** card (about 28 px) slides down at the top centre instead of the full-width bar:
the kind of mention ("Your name" while waiting, then "Asking you" or "Talking about you"), the
ask itself cut with an ellipsis (the recap's "For David:" / "About David:" / "Context:"
prefixes stripped), and the time + how long ago. Hovering opens the context and the words
that were heard; the tooltip has everything. It holds 2 minutes and ignores mouse movement; a
retraction hides it. Sound-alert banners are unchanged.

Re-applies itself after kvmd upgrades via an ALPM PostTransaction hook.

Since 1.3 the `/alerts/` location is outside kvmd's login check (`auth_request off`) and restricted by source network instead (LAN, tailnet, the gateway proxy), with `Access-Control-Allow-Origin: *`, so the snapshot dashboard at monitor.supportandtechnology.com can subscribe to every station's stream cross-origin without cookies. The events carry only the station name and timings.
