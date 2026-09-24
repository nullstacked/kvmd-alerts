#!/bin/bash
# kvmd-alerts - idempotent patcher. Runs on package install/upgrade and from the
# pacman hook after every kvmd upgrade (which overwrites the web files).
#
#   1. Copies alerts.css into the kvmd web tree.
#   2. Reads the station name from /etc/kvmd/listen.conf (STATION=<name>) — the same
#      file kvmd-listen uses. No file -> support unit -> exit 0 without patching.
#   3. Patches index.html (stylesheet link + banner div), session.js (EventSource
#      subscriber that shows the banner; marker-delimited block replaced on upgrade)
#      and /etc/kvmd/nginx/kvmd.ctx-server.conf (auth-gated `location /alerts/`
#      reverse-proxied to pikvm-alert-detect's SSE endpoint on linux:8040).
set -e

SHARE_DIR="/usr/share/kvmd-alerts"
LOG_PREFIX="kvmd-alerts"
WEB_DIR="/usr/share/kvmd/web"
CONF="/etc/kvmd/listen.conf"
NGINX_CONF="/etc/kvmd/nginx/kvmd.ctx-server.conf"

log() { echo "[$LOG_PREFIX] $*"; }
warn() { echo "[$LOG_PREFIX] WARNING: $*" >&2; }

dest="$WEB_DIR/share/css/kvm/alerts.css"
mkdir -p "$(dirname "$dest")"
if [ -f "$dest" ] && cmp -s "$SHARE_DIR/alerts.css" "$dest"; then
    log "SKIPPED (unchanged): alerts.css"
else
    cp "$SHARE_DIR/alerts.css" "$dest"; log "PATCHED: alerts.css"
fi

if [ ! -f "$CONF" ]; then
    log "SKIPPED: no $CONF - support unit, alert banner not installed"; exit 0
fi
STATION=$(sed -n 's/^STATION=//p' "$CONF" | head -n1 | tr -d "\"' \t\r")
if ! printf '%s' "$STATION" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
    warn "FAILED: $CONF has no valid STATION= (got '$STATION')"; exit 1
fi
log "Station: $STATION"
export STATION WEB_DIR NGINX_CONF
NGINX_FLAG=$(mktemp); export NGINX_FLAG

python3 <<'PYEOF'
import os, sys, shutil

STATION    = os.environ["STATION"]
WEB_DIR    = os.environ["WEB_DIR"]
NGINX_CONF = os.environ["NGINX_CONF"]
NGINX_FLAG = os.environ["NGINX_FLAG"]
def log(msg): print(f"[kvmd-alerts] {msg}")

# ---- index.html: css link + banner div ------------------------------------------
path = os.path.join(WEB_DIR, "kvm", "index.html")
if not os.path.exists(path):
    log("FAILED: index.html not found"); sys.exit(1)
content = open(path).read(); changed = False
if "alerts.css" not in content:
    last_css = content.rfind('<link rel="stylesheet"')
    eol = content.find("\n", last_css) if last_css >= 0 else -1
    if eol >= 0:
        content = content[:eol] + '\n\t\t<link rel="stylesheet" href="../share/css/kvm/alerts.css">' + content[eol:]; changed = True
if 'id="kvm-alert-banner"' not in content:
    body_end = content.rfind("</body>")
    if body_end >= 0:
        div = ('\t\t<div id="kvm-alert-banner" class="kvm-alert-banner" data-shown="0" title="Click to dismiss">'
               '<span class="kvm-alert-text"></span><small class="kvm-alert-sub"></small>'
               '<span class="kvm-alert-close">&times;</span></div>\n')
        content = content[:body_end] + div + content[body_end:]; changed = True
if changed:
    open(path, "w").write(content); log("PATCHED: index.html")
else:
    log("SKIPPED (already applied): index.html")

# ---- session.js: EventSource subscriber + banner ---------------------------------
path = os.path.join(WEB_DIR, "share", "js", "kvm", "session.js")
if not os.path.exists(path):
    log("FAILED: session.js not found"); sys.exit(1)
content = open(path).read()
BEGIN = "\t/* kvmd-alerts:begin v1.6.0 */\n"
END   = "\t/* kvmd-alerts:end */\n"
func_js = r"""
	/* kvmd-alerts:begin v1.6.0 */
	var __alertBannerInit = function() {
		let el = document.getElementById("kvm-alert-banner");
		if (!el || el.dataset.initialized) return;
		el.dataset.initialized = "1";
		// Subscribes to this station's isolated-notification-sound events
		// (pikvm-alert-detect on the audio hub, proxied by kvmd-nginx at /alerts/)
		// and shows a big red banner across the top of the video for a while.
		var SHOW_MS = 60000, FAST_MS = 8000, MIN_FLOOR_MS = 1000, es = null, retry_ms = 2000, hide_timer = null, count = 0;
		// v1.5.0: a name event ("your name was just said") holds longer and ignores
		// the mouse rule. A sound alert shortens on movement because movement means
		// you are already at the machine and have seen it; a name banner fills in
		// its second line ~3 s later with what was actually said, and hiding at the
		// 1 s floor would wipe the banner before its answer arrived.
		var NAME_SHOW_MS = 120000, name_event = null; // v1.3.5: stays SHOW_MS (60 s) when the mouse is idle; the first mouse movement while it is up shortens it to FAST_MS (8 s) from when it appeared, floored at MIN_FLOOR_MS from now so it never vanishes instantly (David 2026-09-20: if the mouse is moving, dismiss it faster). Also hides on a click.
		var base_title = document.title, shown_at = 0, fast = false;
		var text = el.querySelector(".kvm-alert-text"), sub = el.querySelector(".kvm-alert-sub");
		// v1.6.0: the name banner is a compact card (alerts.css): a small header saying what
		// kind of mention it was, the answer as the lead line, its context, and the words that
		// were heard. Built here so index.html's banner markup stays the same.
		var mk = function(tag, cls, parent) { var n = document.createElement(tag); n.className = cls; parent.appendChild(n); return n; };
		var nm = mk("div", "kvm-name", el); el.insertBefore(nm, sub);
		var nm_head = mk("span", "kvm-name-head", nm), nm_label = mk("span", "kvm-name-label", nm_head), nm_meta = mk("span", "kvm-name-meta", nm_head);
		var nm_lead = mk("span", "kvm-name-lead", nm), nm_ctx = mk("span", "kvm-name-ctx", nm), nm_wait = mk("span", "kvm-name-wait", nm), nm_quote = mk("span", "kvm-name-quote", nm);
		var nm_when = "", nm_heard = "";
		var nm_set = function(label, meta, lead, ctx, wait, quote) {
			nm_label.textContent = label; nm_meta.textContent = meta; nm_lead.textContent = lead;
			nm_ctx.textContent = ctx; nm_wait.textContent = wait; nm_quote.textContent = quote;
			[nm_ctx, nm_wait, nm_quote].forEach(function(n) { n.style.display = n.textContent ? "" : "none"; });
		};
		var hide = function() { el.dataset.shown = "0"; clearTimeout(hide_timer); fast = false; name_event = null; document.title = base_title; };
		// v1.5.0: stage 2 of a name event, ~3 s behind stage 1 and carrying the same
		// event_id — the recap's answer, or a retraction when nobody was actually
		// addressing you (a video playing in the room, or a mishear). Only ever
		// touches the banner it belongs to, so a sound alert in between wins the
		// banner and the late answer is dropped rather than overwriting it.
		var answer = function(ev) {
			if (!name_event || ev.event_id !== name_event || el.dataset.shown !== "1") return;
			if (ev.dismiss) { hide(); return; }
			// The recap answers "For David: <ask>" / "About David: <gist>", then "Context: …",
			// ending "(29s ago)". Show the ask as the lead, without the prefixes.
			var lines = String(ev.answer || ev.note || "").split("\n").map(function(x) { return x.trim(); }).filter(Boolean);
			var ago = "", m, lead = "", ctx = [], verdict = ev.verdict || "";
			if (lines.length && (m = lines[lines.length - 1].match(/\s*\((\d+\s*[smh] ago)\)\s*$/))) {
				ago = m[1]; lines[lines.length - 1] = lines[lines.length - 1].slice(0, m.index).trim();
			}
			lines.forEach(function(ln, i) {
				var p = ln.match(/^(for|about)\s+[^:]{1,30}:\s*/i), c = ln.match(/^context:\s*/i);
				if (i === 0 && p) { verdict = p[1].toLowerCase() === "about" ? "about" : "asked"; lead = ln.slice(p[0].length); }
				else if (c) ctx.push(ln.slice(c[0].length));
				else if (!lead) lead = ln;
				else ctx.push(ln);
			});
			el.dataset.verdict = verdict;
			var label = verdict === "asked" ? "🗣️ Asking you" : verdict === "about" ? "🗣️ Talking about you" : "🗣️ Your name";
			nm_set(label, nm_when + (ago ? " · " + ago : ""), lead || nm_heard, ctx.join(" "), "", lead ? nm_heard : "");
		};
		var show = function(ev) {
			if (ev.kind === "name" && ev.stage === "answer") { answer(ev); return; }
			count += 1;
			var when = "";
			try { when = new Date(ev.ts).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"}); } catch (e) {}
			// v1.4.0: the detector says what it heard — kind "call" (a ringing call: it
			// always alerts, even mid-meeting after a pause) or "alert" (a message ping) —
			// and sends a ready label ("📞 Sound detected: possible call"). Older detectors
			// send neither: plain "Sound detected".
			var kind = (ev.kind === "call" || ev.kind === "alert" || ev.kind === "name") ? ev.kind : "";
			text.textContent = (ev.label || "🔔 Sound detected") + (when ? " at " + when : "");
			// A name banner opens with the words that triggered it, so one glance
			// settles a mishear without waiting for the answer.
			sub.textContent = "";
			name_event = (kind === "name") ? (ev.event_id || null) : null;
			if (kind === "name") {
				nm_when = when; nm_heard = ev.heard ? "\u201c" + ev.heard + "\u201d" : "";
				el.dataset.verdict = "";
				nm_set("🗣️ Your name", when, nm_heard || "Your name was just said", "", "Working out what they want\u2026", "");
			}
			el.dataset.kind = kind;
			el.dataset.shown = "1"; shown_at = Date.now(); fast = false;
			base_title = document.title.replace(/^(🔔|📞|🗣️) /, "");
			document.title = (kind === "call" ? "📞 " : kind === "name" ? "🗣️ " : "🔔 ") + base_title;
			clearTimeout(hide_timer); hide_timer = setTimeout(hide, kind === "name" ? NAME_SHOW_MS : SHOW_MS);
		};
		var connect = function() {
			try { if (es) es.close(); } catch (e) {}
			es = new EventSource("/alerts/?t=" + Date.now());
			es.onopen = function() { retry_ms = 2000; };
			es.onmessage = function(m) { try { show(JSON.parse(m.data)); } catch (e) {} };
			es.onerror = function() { try { es.close(); } catch (e) {} es = null; setTimeout(connect, retry_ms); retry_ms = Math.min(retry_ms * 2, 30000); };
		};
		document.addEventListener("mousemove", function() {
			if (el.dataset.shown !== "1" || fast) return;   // only the first movement shortens it
			if (el.dataset.kind === "name") return;         // v1.5.0: a summons waits for its answer
			fast = true;
			var delay = Math.max(FAST_MS - (Date.now() - shown_at), MIN_FLOOR_MS);
			clearTimeout(hide_timer); hide_timer = setTimeout(hide, delay);
		}, {passive: true});
		el.addEventListener("click", hide);
		// Sticky user activation is not needed: EventSource is not autoplay-gated.
		connect();
		window.addEventListener("beforeunload", function() { try { if (es) es.close(); } catch (e) {} });
	};
	document.addEventListener("DOMContentLoaded", __alertBannerInit);
	if (document.readyState !== "loading") __alertBannerInit();
	/* kvmd-alerts:end */

"""
if BEGIN in content and func_js in content:
    log("SKIPPED (already applied): session.js")
else:
    if "/* kvmd-alerts:begin" in content and END in content:
        a = content.index("\n\t/* kvmd-alerts:begin"); b = content.index(END) + len(END)
        content = content[:a] + content[b:]; log("removed previous kvmd-alerts block from session.js")
    target = '\tvar __wsJsonHandler = function(ev_type, ev) {'
    if target in content:
        content = content.replace(target, func_js + target, 1)
        open(path, "w").write(content); log("PATCHED: session.js")
    else:
        log("FAILED: session.js anchor not found"); sys.exit(1)

# ---- nginx: auth-gated SSE proxy -------------------------------------------------
MARK = "# ===== kvmd-alerts: notification-sound events (auth required) ====="
ANCHOR = "# ===== uStreamer for MJPEG (auth required) ====="
block = (
    MARK + "\n\n"
    "location /alerts/ {\n"
    "\t# text/event-stream from pikvm-alert-detect on linux:8040 for this station.\n"
    "\t# 1.3: no kvmd login check (a cross-origin EventSource from the snapshot\n"
    "\t# dashboard carries no cookie) — the events are just 'station X had a chime\n"
    "\t# at T', so source-network restriction is enough: LAN, tailnet, and\n"
    "\t# gatewayserver (the public-path proxy, whose users already passed auth).\n"
    "\tauth_request off;\n"
    "\tallow 127.0.0.1; allow 192.168.100.0/24; allow 100.64.0.0/10; allow fd7a:115c:a1e0::/48; deny all;\n"
    "\t# Variable upstream + resolver (kvmd-nginx starts even if DNS/linux is down);\n"
    "\t# with a variable in proxy_pass the URI below is sent verbatim.\n"
    "\tresolver 192.168.100.132 192.168.100.129 valid=60s ipv6=off;\n"
    "\tset $alerts_upstream linux.domain.supportandtechnology.com;\n"
    "\tproxy_pass http://$alerts_upstream:8040/events/" + STATION + ";\n"
    "\tproxy_http_version 1.1;\n"
    "\tproxy_set_header Connection \"\";\n"
    "\tproxy_set_header Host $alerts_upstream;\n"
    "\tproxy_set_header X-Real-IP $remote_addr;\n"
    "\tproxy_buffering off;\n"
    "\tproxy_cache off;\n"
    "\tproxy_read_timeout 7d;\n"
    "\tproxy_send_timeout 7d;\n"
    "\tchunked_transfer_encoding off;\n"
    "\tadd_header Cache-Control \"no-store\" always;\n"
    "\tadd_header X-Accel-Buffering \"no\" always;\n"
    "\t# 1.2: the snapshot dashboard (monitor.supportandtechnology.com) subscribes\n"
    "\t# cross-origin with credentials (IP auto-login / kvmd cookie).\n"
    "\tadd_header Access-Control-Allow-Origin \"*\" always;\n"
    "}\n\n"
)
if not os.path.exists(NGINX_CONF):
    log("FAILED: nginx conf not found"); sys.exit(1)
content = open(NGINX_CONF).read(); new_content = content
if MARK in content:
    start = content.find(MARK); nxt = content.find("\n# =====", start + len(MARK))
    end = (nxt + 1) if nxt >= 0 else len(content)
    if content[start:end] != block:
        new_content = content[:start] + block + content[end:]
elif ANCHOR in content:
    idx = content.find(ANCHOR); new_content = content[:idx] + block + content[idx:]
else:
    log("FAILED: nginx anchor not found"); sys.exit(1)
if new_content != content:
    shutil.copy2(NGINX_CONF, NGINX_CONF + ".bak.kvmd-alerts")
    open(NGINX_CONF, "w").write(new_content); open(NGINX_FLAG, "w").write("1")
    log("PATCHED: nginx (location /alerts/ -> linux:8040/events/" + STATION + ")")
else:
    log("SKIPPED (already applied): nginx")
PYEOF

if [ "$(cat "$NGINX_FLAG" 2>/dev/null)" = "1" ]; then
    if systemctl is-enabled --quiet kvmd-nginx 2>/dev/null || systemctl is-active --quiet kvmd-nginx 2>/dev/null; then
        log "Restarting kvmd-nginx"
        if ! systemctl restart kvmd-nginx || ! systemctl is-active --quiet kvmd-nginx; then
            warn "kvmd-nginx failed to start with the new config - rolling back"
            cp -a "$NGINX_CONF.bak.kvmd-alerts" "$NGINX_CONF"; systemctl restart kvmd-nginx || true
            rm -f "$NGINX_FLAG"; exit 1
        fi
    fi
fi
rm -f "$NGINX_FLAG"
log "Done"
