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
BEGIN = "\t/* kvmd-alerts:begin v1.7.0 */\n"
END   = "\t/* kvmd-alerts:end */\n"
func_js = r"""
	/* kvmd-alerts:begin v1.7.0 */
	var __alertBannerInit = function() {
		let el = document.getElementById("kvm-alert-banner");
		if (!el || el.dataset.initialized) return;
		el.dataset.initialized = "1";
		// Subscribes to this station's events from pikvm-alert-detect on the audio hub (proxied by
		// kvmd-nginx at /alerts/): sound alerts ("alert" = a message ping, "call" = a ring) and
		// name mentions ("name", from pikvm-name-watch). 1.7.0: one line, 85% wide; a mention is
		// solid dark red and flashes, everything else is a muted bar with a coloured edge that
		// flashes twice and then pulses (alerts.css). Stage-2 events fill the banner in later:
		// a name's recap answer, or a sound's source (which app, who, what they wrote).
		var SHOW_MS = 60000, FAST_MS = 8000, MIN_FLOOR_MS = 1000, NAME_SHOW_MS = 120000;
		var es = null, retry_ms = 2000, hide_timer = null, cur_event = null, shown_at = 0, fast = false;
		var base_title = document.title;
		var LOGO = {
			teams: '<svg viewBox="0 0 24 24"><rect x="1" y="4" width="15" height="16" rx="3" fill="#5b5fc7"/><text x="8.5" y="16.5" font-size="11" font-weight="800" text-anchor="middle" fill="#fff" font-family="sans-serif">T</text><circle cx="19.5" cy="7.5" r="3" fill="#7b83eb"/><rect x="16" y="11" width="7" height="8" rx="2.5" fill="#7b83eb"/></svg>',
			slack: '<svg viewBox="0 0 24 24"><rect width="24" height="24" rx="5" fill="#fff"/><rect x="5" y="9.5" width="9" height="3" rx="1.5" fill="#36c5f0"/><rect x="11.5" y="5" width="3" height="9" rx="1.5" fill="#2eb67d"/><rect x="10" y="11.5" width="9" height="3" rx="1.5" fill="#ecb22e"/><rect x="9.5" y="10" width="3" height="9" rx="1.5" fill="#e01e5a"/></svg>',
			outlook: '<svg viewBox="0 0 24 24"><rect x="7" y="4" width="16" height="16" rx="2" fill="#28a8ea"/><rect x="1" y="6" width="13" height="12" rx="2" fill="#0f6cbd"/><circle cx="7.5" cy="12" r="3.3" fill="none" stroke="#fff" stroke-width="2"/></svg>',
			google_chat: '<svg viewBox="0 0 24 24"><path d="M3 4h18v12H9l-4 4v-4H3z" fill="#1e8e3e"/><circle cx="8" cy="10" r="1.4" fill="#fff"/><circle cx="12" cy="10" r="1.4" fill="#fff"/><circle cx="16" cy="10" r="1.4" fill="#fff"/></svg>',
			zoom: '<svg viewBox="0 0 24 24"><rect width="24" height="24" rx="6" fill="#2d8cff"/><rect x="4" y="8" width="11" height="8" rx="2" fill="#fff"/><path d="M16 11l4-3v8l-4-3z" fill="#fff"/></svg>',
			sound: '<svg viewBox="0 0 24 24"><path d="M3 9h4l5-4v14l-5-4H3z" fill="#f0b429"/><path d="M15 8.5a5 5 0 0 1 0 7M17.5 6a8.5 8.5 0 0 1 0 12" stroke="#f0b429" stroke-width="2" fill="none" stroke-linecap="round"/></svg>',
			phone: '<svg viewBox="0 0 24 24"><path d="M6.6 2.5l3 4-2 2.5a12 12 0 0 0 7.4 7.4l2.5-2 4 3-1.8 3.8C13 21 3 11 2.8 4.3z" fill="#ff8a3d"/></svg>',
			mention: '<svg viewBox="0 0 24 24"><path d="M3 4h18v12H10l-5 4v-4H3z" fill="#fff"/><text x="12" y="13.5" font-size="9" font-weight="800" text-anchor="middle" fill="#a51d1d" font-family="sans-serif">@</text></svg>',
			about: '<svg viewBox="0 0 24 24"><path d="M3 4h18v12H10l-5 4v-4H3z" fill="#ef9a9a"/><text x="12" y="13.5" font-size="9" font-weight="800" text-anchor="middle" fill="#1b2230" font-family="sans-serif">@</text></svg>'
		};
		var APP = {teams: "Teams", slack: "Slack", outlook: "Outlook", google_chat: "Chat", zoom: "Zoom"};
		var mk = function(tag, cls) { var n = document.createElement(tag); n.className = cls; el.appendChild(n); return n; };
		var close = el.querySelector(".kvm-alert-close");
		var pill = mk("span", "kvm-b-pill"), lead = mk("span", "kvm-b-lead"), meta = mk("span", "kvm-b-meta"), more = mk("div", "kvm-b-more");
		if (close) el.appendChild(close);
		var set = function(logo, label, lead_nodes, meta_text, more_nodes) {
			pill.innerHTML = LOGO[logo] || "";                 // static markup from the table above only
			pill.appendChild(document.createTextNode(label));
			lead.textContent = ""; (lead_nodes || []).forEach(function(n) { lead.appendChild(typeof n === "string" ? document.createTextNode(n) : n); });
			meta.textContent = meta_text || "";
			more.textContent = ""; (more_nodes || []).forEach(function(n) { more.appendChild(n); });
			el.title = [label, lead.textContent].concat((more_nodes || []).map(function(n) { return n.textContent; })).filter(Boolean).join("\n") + "\n(click to dismiss)";
		};
		var quote = function(t) { var q = document.createElement("q"); q.textContent = t; return q; };
		var line = function(tag, t) { var n = document.createElement(tag); n.textContent = t; return n; };
		var hide = function() { el.dataset.shown = "0"; clearTimeout(hide_timer); fast = false; cur_event = null; document.title = base_title; };
		var restart = function() { el.dataset.shown = "0"; void el.offsetWidth; el.dataset.shown = "1"; };   // re-runs the arrival flash
		var hhmm = function(ts) { try { return new Date(ts).toLocaleTimeString([], {hour: "numeric", minute: "2-digit"}); } catch (e) { return ""; } };
		var when = "", heard = "";
		// A sound's source (stage "source"): "Teams · Rahul Jonnakuti: “…”".
		var source = function(ev) {
			if (!cur_event || ev.event_id !== cur_event || el.dataset.shown !== "1" || el.dataset.kind === "name") return;
			var s = ev.source || {}, app = APP[s.app] || (s.app === "chat" ? (s.client || "Chat") : "");
			var call = el.dataset.kind === "call";
			var label = app ? (call ? app + " call" : app) : (call ? "Call" : "Sound");
			var what = {email: "Email", reminder: "Reminder", meeting: "Meeting reminder", call: "Incoming call"}[s.what] || "";
			var nodes = [];
			if (s.sender) nodes.push((call ? "Incoming call from " : "") + s.sender + (s.snippet && !call ? ": " : ""));
			else if (what) nodes.push(what + (s.snippet ? ": " : ""));
			if (s.snippet && !call) nodes.push(quote(s.snippet));
			if (!nodes.length) nodes.push(call ? "Possible incoming call" : "Possible alert");
			set(LOGO[s.app] ? s.app : (s.app === "chat" ? "google_chat" : (call ? "phone" : "sound")), label, nodes, when);
		};
		// A name's recap answer (stage "answer"): "For David: <ask>" / "About David: …", "Context: …", "(29s ago)".
		var answer = function(ev) {
			if (!cur_event || ev.event_id !== cur_event || el.dataset.shown !== "1") return;
			if (ev.dismiss) { hide(); return; }
			var lines = String(ev.answer || ev.note || "").split("\n").map(function(x) { return x.trim(); }).filter(Boolean);
			var ago = "", m, ask = "", ctx = [], verdict = ev.verdict || "";
			if (lines.length && (m = lines[lines.length - 1].match(/\s*\((\d+\s*[smh] ago)\)\s*$/))) {
				ago = m[1]; lines[lines.length - 1] = lines[lines.length - 1].slice(0, m.index).trim();
			}
			lines.forEach(function(ln, i) {
				var p = ln.match(/^(for|about)\s+[^:]{1,30}:\s*/i), c = ln.match(/^context:\s*/i);
				if (i === 0 && p) { verdict = p[1].toLowerCase() === "about" ? "about" : "asked"; ask = ln.slice(p[0].length); }
				else if (c) ctx.push(ln.slice(c[0].length));
				else if (!ask) ask = ln;
				else ctx.push(ln);
			});
			el.dataset.verdict = verdict;
			el.classList.toggle("kvm-mention", verdict !== "about");
			var more_nodes = [];
			if (ctx.length) more_nodes.push(line("span", ctx.join(" ")));
			if (heard && ask) more_nodes.push(line("i", "\u201c" + heard + "\u201d"));
			set(verdict === "about" ? "about" : "mention", verdict === "asked" ? "Asking you" : verdict === "about" ? "About you" : "Your name",
			    [ask || (heard ? quote(heard) : "Your name was just said")], when + (ago ? " \u00b7 " + ago : ""), more_nodes);
		};
		var show = function(ev) {
			if (ev.kind === "name" && ev.stage === "answer") { answer(ev); return; }
			if (ev.stage === "source") { source(ev); return; }
			var kind = (ev.kind === "call" || ev.kind === "alert" || ev.kind === "name") ? ev.kind : "alert";
			when = hhmm(ev.ts);
			cur_event = ev.event_id || null;
			el.dataset.kind = kind;
			el.dataset.verdict = "";
			el.classList.toggle("kvm-mention", kind === "name");
			if (kind === "name") {
				heard = ev.heard || "";
				set("mention", "Your name", [heard ? quote(heard) : "Your name was just said"], when + " \u00b7 working\u2026");
			} else if (kind === "call") {
				set("phone", "Call", ["Possible incoming call" + (ev.test ? " (test)" : "")], when);
			} else {
				set("sound", "Sound", ["Possible alert" + (ev.test ? " (test)" : "")], when);
			}
			restart(); shown_at = Date.now(); fast = false;
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
		// Moving the mouse on this page means you are at this machine and have seen it: a sound
		// banner then goes 8 s after it appeared. A mention waits for its answer (v1.5.0).
		document.addEventListener("mousemove", function() {
			if (el.dataset.shown !== "1" || fast || el.dataset.kind === "name") return;
			fast = true;
			var delay = Math.max(FAST_MS - (Date.now() - shown_at), MIN_FLOOR_MS);
			clearTimeout(hide_timer); hide_timer = setTimeout(hide, delay);
		}, {passive: true});
		el.addEventListener("click", hide);
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
