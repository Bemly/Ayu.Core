# render.sh — server-side XML + CSS for the dashboard
#
# The panel is a single XML document. The browser never sees HTML: the CGI
# emits `text/xml` plus a `<?xml-stylesheet type="text/css"?>` processing
# instruction, and everything the eye sees comes from one CSS file that the
# same CGI generates (cgi-bin/web.sh?css=1). No JavaScript anywhere.
#
# Two engine facts drive this file — both measured in Chromium, not assumed:
#
#   1. In an XML document the reader is not HTML, so `class` carries no extra
#      meaning: `.top` style selectors never match. `face[class="top"]` and the
#      element-name selectors do. Every rule below therefore uses names and
#      attribute selectors only.
#   2. Elements get no HTML semantics either. <a> is not a link and <input> is
#      not a control — clicks do nothing. The only input channels left to pure
#      CSS are :hover and :active, and each can fire one CSS background-image
#      request per page load. That is how the pause/resume pads talk to
#      cgi-bin/act.sh.
#
# Output rules:
#   * every value from disk/config goes through render_esc() / render_attr()
#   * styles live in render_css() and are served with text/css
#   * only functions with the _r_ prefix touch unescaped values

# --- escaping / formatting ----------------------------------------------

# render_esc <text> — escape for XML text nodes
# Also drops the control bytes XML 1.0 forbids outright: a log file with a stray
# ESC or NUL must not be able to invalidate the whole document.
render_esc() {
	printf '%s' "${1:-}" | tr -d '\000-\010\013\014\016-\037' | sed \
		-e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
		-e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# render_attr <text> — escape for an attribute value
# Newlines and tabs become spaces: XML attribute-value normalisation would fold
# them anyway, and a folding surprise in an attribute is hard to debug.
render_attr() {
	printf '%s' "${1:-}" | tr '\n\r\t' '   ' | tr -d '\000-\010\013\014\016-\037' | sed \
		-e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
		-e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# render_bytes <bytes> — human-readable size
render_bytes() {
	_r_v="$(printf '%s' "${1:-0}" | tr -dc '0-9')"
	[ -n "$_r_v" ] || _r_v=0
	if [ "$_r_v" -lt 1024 ]; then
		printf '%s B' "$_r_v"
	elif [ "$_r_v" -lt 1048576 ]; then
		printf '%s KB' "$((_r_v / 1024))"
	elif [ "$_r_v" -lt 1073741824 ]; then
		printf '%s MB' "$((_r_v / 1048576))"
	else
		printf '%s GB' "$((_r_v / 1073741824))"
	fi
}

# render_kb <kib> — same, for values already expressed in KB
render_kb() {
	_r_v="$(printf '%s' "${1:-0}" | tr -dc '0-9')"
	[ -n "$_r_v" ] || _r_v=0
	render_bytes "$((_r_v * 1024))"
}

# render_duration <seconds> — "3 天 4 小时" / "5 小时 12 分" / "8 分"
render_duration() {
	_r_v="$(printf '%s' "${1:-0}" | tr -dc '0-9')"
	[ -n "$_r_v" ] || _r_v=0
	if [ "$_r_v" -ge 86400 ]; then
		printf '%s 天 %s 小时' "$((_r_v / 86400))" "$(((_r_v % 86400) / 3600))"
	elif [ "$_r_v" -ge 3600 ]; then
		printf '%s 小时 %s 分' "$((_r_v / 3600))" "$(((_r_v % 3600) / 60))"
	else
		printf '%s 分' "$((_r_v / 60))"
	fi
}

# render_flag <value> [tone-when-set] — badge element for a configured key
render_flag() {
	if [ -n "${1:-}" ]; then
		printf '<badge tone="%s">已配置</badge>' "${2:-ok}"
	else
		printf '<badge tone="off">未配置</badge>'
	fi
}

# --- document chrome -----------------------------------------------------

# render_head <title> <css-nonce>
# The stylesheet URL is CDN-proof and cache-proof: the nonce changes every
# render, so a stale cached CSS can never carry a dead command URL.
render_head() {
	printf '<?xml version="1.0" encoding="UTF-8"?>\n'
	printf '<?xml-stylesheet type="text/css" href="/cgi-bin/web.sh?css=1&amp;n=%s"?>\n' \
		"$(render_attr "${2:-0}")"
	printf '<panel>\n'
	printf '<bar>\n<brand>Ayu <dim>Console</dim></brand>\n'
	printf '<hint>%s</hint>\n' "$(render_esc "${1:-Ayu}")"
	printf '</bar>\n'
}

# render_tabs <active> — filled pills, not links: XML has no clickable anchors,
# so this is a position marker rather than navigation.
render_tabs() {
	_r_t_over=""; _r_t_sync=""; _r_t_logs=""; _r_t_conf=""
	case "${1:-all}" in
		overview) _r_t_over=' state="on"' ;;
		sync)     _r_t_sync=' state="on"' ;;
		logs)     _r_t_logs=' state="on"' ;;
		config)   _r_t_conf=' state="on"' ;;
		*)        ;;
	esac
	printf '<tabs>'
	printf '<tab%s>概览</tab>' "$_r_t_over"
	printf '<tab%s>同步</tab>' "$_r_t_sync"
	printf '<tab%s>日志</tab>' "$_r_t_logs"
	printf '<tab%s>设置</tab>' "$_r_t_conf"
	printf '</tabs>\n'
}

# render_foot <version-line>
render_foot() {
	printf '<footer>%s</footer>\n' "$(render_esc "${1:-}")"
	printf '</panel>\n'
}

# render_pads <nonce> <paused|running>
# The pads are the only writable surface. Each one is a :active background
# image, so a mouse press is the request: pressed → GET act.sh. Deliberately
# limited to non-destructive state (refresh on/off) — see cgi-bin/act.sh.
render_pads() {
	_r_state="${2:-running}"
	printf '<padbar>'
	if [ "$_r_state" = "paused" ]; then
		printf '<pad op="resume">恢复自动刷新</pad>'
		printf '<pad op="pause" inert="1">已暂停</pad>'
	else
		printf '<pad op="pause">暂停自动刷新</pad>'
	fi
	printf '</padbar>\n'
}

# --- 3D blocks -----------------------------------------------------------

# render_cube <label> <value> <tone>
# One Minecraft-style block per headline gauge. tone picks the palette in CSS
# (ok=grass, warn=gold, err=redstone, off=stone); the geometry is identical.
render_cube() {
	printf '<cube tone="%s" label="%s" value="%s">' \
		"$(render_attr "${3:-ok}")" "$(render_attr "${1:-}")" "$(render_attr "${2:-}")"
	printf '<rotor>'
	printf '<face class="top"/><face class="front"/><face class="right"/>'
	printf '<face class="left"/><face class="back"/><face class="bottom"/>'
	printf '</rotor><shade/></cube>\n'
}

# --- content blocks ------------------------------------------------------

# render_stat <label> <value-html>
render_stat() {
	printf '<stat label="%s" value="%s"/>\n' "$(render_attr "${1:-}")" "$(render_attr "${2:-}")"
}

# render_kv <key> <value-html>  — value may be inline markup (badge, code)
render_kv() {
	printf '<kv k="%s"><v>%s</v></kv>\n' "$(render_attr "${1:-}")" "${2:-}"
}

# render_card_open <heading-html> [tone]
render_card_open() {
	printf '<card%s><h2>%s</h2>\n' \
		"$([ -n "${2:-}" ] && printf ' tone="%s"' "$(render_attr "$2")")" "$1"
}

# render_card_close
render_card_close() {
	printf '</card>\n'
}

# render_line <text> — one log line, toned by its own content
render_line() {
	_r_l="$(render_esc "$1")"
	case "$1" in
		*ERROR*|*FAIL*|*fatal*) printf '<line tone="err">%s</line>\n' "$_r_l" ;;
		*WARN*)                 printf '<line tone="warn">%s</line>\n' "$_r_l" ;;
		*)                      printf '<line>%s</line>\n' "$_r_l" ;;
	esac
}

# --- stylesheet ----------------------------------------------------------

# render_css <nonce>
# One sheet, no external fonts, no images. Everything decorative is CSS
# (gradients, shadows, 3D transforms).
render_css() {
	_r_nonce="$(printf '%s' "${1:-0}" | tr -dc '0-9a-f')"
	[ -n "$_r_nonce" ] || _r_nonce=0
	# The replacement is escaped because sed treats '&' as "whole match" and
	# the command URL needs a literal one.
	_r_base="/cgi-bin/act.sh?n=$_r_nonce"
	_r_base_esc="$(printf '%s' "$_r_base" | sed 's/&/\\&/g')"

	cat <<'CSS' | sed "s#__NONCEBASE__#$_r_base_esc#g"
/* Ayu dashboard — XML document, styled by CSS only. No JS, no HTML. */
panel, bar, brand, dim, hint, tabs, tab, padbar, pad, scene, cube, rotor,
face, shade, sheet, grid, stat, card, h2, kv, v, badge, log, line, footer,
note, tips, sec { display: block; }

panel {
  margin: 0;
  padding: 0;
  background: #0e1116;
  color: #dfe3ea;
  font: 13px/1.55 ui-monospace, "JetBrains Mono", Menlo, Consolas,
        "Noto Sans Mono CJK SC", monospace;
}

* { box-sizing: border-box; }

/* ---- top bar ---- */
bar {
  display: flex; align-items: center; gap: 12px;
  padding: 11px 18px;
  background: linear-gradient(#151a22, #11151c);
  border-bottom: 1px solid #232833;
}
brand { font-size: 15px; font-weight: 700; letter-spacing: .6px; }
dim { display: inline; color: #7d8797; font-weight: 400; }
hint { margin-left: auto; color: #5d6675; font-size: 11px; }

tabs { display: flex; gap: 4px; margin-left: 10px; }
tab {
  padding: 3px 10px; border-radius: 6px; font-size: 12px;
  color: #8b96a7; border: 1px solid transparent;
}
tab[state="on"] {
  background: #1d2430; color: #e8eef8; border-color: #2c3444;
}

padbar { margin-left: auto; display: flex; gap: 8px; }
pad {
  display: inline-block;
  padding: 4px 11px; border-radius: 6px;
  font-size: 12px; color: #c6d2e2; cursor: pointer;
  border: 1px solid #2c3444;
  background: #151a22;
  user-select: none;
  background-repeat: no-repeat;
}
pad:hover { border-color: #3d5a80; color: #e8eef8; }
pad:active { background-color: #233047; border-color: #4a6b96; }
pad[inert="1"] { color: #6a7484; cursor: default; }

/* The two command channels: one CSS request each, fired on mouse-down.
   act.sh answers with a 1x1 GIF and flips the pause flag server-side. */
pad[op="pause"]:active  { background-image: url("__NONCEBASE__&op=pause"); }
pad[op="resume"]:active { background-image: url("__NONCEBASE__&op=resume"); }

/* ---- 3D voxel scene (CSS-Minecraft style) ---- */
scene {
  display: flex; justify-content: center; align-items: flex-end;
  gap: 44px;
  padding: 60px 18px 66px;
  perspective: 1000px;
  perspective-origin: 50% 35%;
  overflow: hidden;
  background:
    radial-gradient(120% 80% at 50% 0%, #16202b 0%, #0e1116 60%),
    linear-gradient(#0e1116, #0b0e13);
  border-bottom: 1px solid #1b2029;
}

cube { position: relative; width: 56px; height: 56px; }
cube::before {
  content: attr(label);
  position: absolute; top: -22px; left: 50%;
  transform: translateX(-50%);
  white-space: nowrap; font-size: 11px; color: #8b96a7;
}
cube::after {
  content: attr(value);
  position: absolute; bottom: -34px; left: 50%;
  transform: translateX(-50%);
  white-space: nowrap; font-size: 12px; font-weight: 600; color: #e8eef8;
}

rotor {
  position: absolute; top: 0; left: 0; width: 56px; height: 56px;
  transform-style: preserve-3d;
  transform: rotateX(-20deg) rotateY(-35deg);
  animation: spin 26s linear infinite;
}
@keyframes spin {
  from { transform: rotateX(-20deg) rotateY(0deg); }
  to   { transform: rotateX(-20deg) rotateY(360deg); }
}
cube:hover rotor { animation-play-state: paused; }

face {
  position: absolute; top: 0; left: 0;
  width: 56px; height: 56px;
  border: 1px solid rgba(0, 0, 0, .45);
  background: #444;
}
face[class="front"]  { transform: translateZ(28px); }
face[class="back"]   { transform: rotateY(180deg) translateZ(28px); }
face[class="right"]  { transform: rotateY(90deg) translateZ(28px); }
face[class="left"]   { transform: rotateY(-90deg) translateZ(28px); }
face[class="top"]    { transform: rotateX(90deg) translateZ(28px); }
face[class="bottom"] { transform: rotateX(-90deg) translateZ(28px); }

/* grass block — healthy */
cube[tone="ok"] face[class="top"]    { background: #6fae3f; }
cube[tone="ok"] face[class="front"]  { background: linear-gradient(#6fae3f 0 16%, #8a6240 16%); }
cube[tone="ok"] face[class="back"]   { background: linear-gradient(#5f9a35 0 16%, #7a5638 16%); }
cube[tone="ok"] face[class="left"]   { background: linear-gradient(#5f9a35 0 16%, #6f4e32 16%); }
cube[tone="ok"] face[class="right"]  { background: linear-gradient(#5a9130 0 16%, #66482e 16%); }
cube[tone="ok"] face[class="bottom"] { background: #4a3524; }

/* gold block — attention */
cube[tone="warn"] face[class="top"]    { background: #f2ce4a; }
cube[tone="warn"] face[class="front"]  { background: #d9b02c; }
cube[tone="warn"] face[class="back"]   { background: #c39d24; }
cube[tone="warn"] face[class="left"]   { background: #b08c1f; }
cube[tone="warn"] face[class="right"]  { background: #a8821b; }
cube[tone="warn"] face[class="bottom"] { background: #85660f; }

/* redstone block — fault */
cube[tone="err"] face[class="top"]    { background: #d4503f; }
cube[tone="err"] face[class="front"]  { background: #b83c2d; }
cube[tone="err"] face[class="back"]   { background: #a33325; }
cube[tone="err"] face[class="left"]   { background: #8f2b1e; }
cube[tone="err"] face[class="right"]  { background: #7d2418; }
cube[tone="err"] face[class="bottom"] { background: #5e1a11; }

/* stone — not configured */
cube[tone="off"] face[class="top"]    { background: #9aa7ae; }
cube[tone="off"] face[class="front"]  { background: #7d8a92; }
cube[tone="off"] face[class="back"]   { background: #6d7a82; }
cube[tone="off"] face[class="left"]   { background: #5f6b73; }
cube[tone="off"] face[class="right"]  { background: #55616a; }
cube[tone="off"] face[class="bottom"] { background: #414b52; }

shade {
  position: absolute; left: -12px; bottom: -12px;
  width: 80px; height: 14px; border-radius: 50%;
  background: rgba(0, 0, 0, .45);
  filter: blur(5px);
}

@media (prefers-reduced-motion: reduce) {
  rotor { animation: none; }
}

/* ---- content ---- */
sheet { padding: 20px 18px 0; max-width: 1160px; margin: 0 auto; }

grid {
  display: grid; gap: 12px;
  grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
  margin-bottom: 16px;
}
stat {
  background: #151a22; border: 1px solid #232833;
  border-radius: 8px; padding: 12px 14px;
}
stat::before {
  content: attr(label); display: block;
  color: #8492a6; font-size: 11px; letter-spacing: .4px;
}
stat::after {
  content: attr(value); display: block;
  margin-top: 4px; font-size: 18px; font-weight: 600; color: #e8eef8;
}

card {
  background: #151a22; border: 1px solid #232833;
  border-radius: 8px; margin-bottom: 16px; overflow: hidden;
}
card > h2 {
  margin: 0; padding: 9px 14px;
  font-size: 12px; font-weight: 600; letter-spacing: .5px;
  color: #a9b3c3; background: #171c25;
  border-bottom: 1px solid #232833;
}

kv {
  display: flex; gap: 16px; justify-content: space-between;
  padding: 8px 14px; border-bottom: 1px solid #1f242e;
}
kv:last-child { border-bottom: 0; }
kv::before { content: attr(k); color: #8492a6; flex: 0 0 auto; }
v { color: #dfe3ea; text-align: right; word-break: break-all; }

badge {
  display: inline-block; padding: 1px 8px; border-radius: 999px;
  font-size: 11px; border: 1px solid #2c3444; color: #a9b3c3;
}
badge[tone="ok"]  { color: #6ede9c; border-color: #2d6a4f; background: #12251b; }
badge[tone="off"] { color: #7d8797; border-color: #2a3140; background: #12151b; }

log {
  background: #0a0d12; padding: 10px 14px;
  max-height: 46vh; overflow: auto;
}
line {
  display: block; white-space: pre-wrap; word-break: break-all;
  font-size: 13px; line-height: 1.55; color: #b9c4d4;
}
line[tone="err"]  { color: #ff7b72; }
line[tone="warn"] { color: #e3b341; }

note, tips { color: #7d8797; font-size: 12px; padding: 0 14px 12px; }
sec {
  padding: 10px 14px; color: #8492a6; font-size: 11px;
  letter-spacing: 1px; text-transform: uppercase;
}

footer {
  padding: 16px 18px 28px;
  text-align: center; color: #4d5563; font-size: 11px;
}
CSS
}

# --- stylesheet for the gate / error document ---------------------------

# render_gate_css — the same palette, minus the voxel scene. Kept small: the
# gate is one paragraph and a command to copy.
render_gate_css() {
	cat <<'CSS'
panel, bar, brand, dim, hint, sheet, card, h2, kv, v, code, note, stat, footer { display: block; }
* { box-sizing: border-box; }
panel { margin: 0; background: #0e1116; color: #dfe3ea;
  font: 13px/1.6 ui-monospace, Menlo, Consolas, "Noto Sans Mono CJK SC", monospace; }
bar { display: flex; align-items: center; gap: 12px; padding: 11px 18px;
  background: #151a22; border-bottom: 1px solid #232833; }
brand { font-size: 15px; font-weight: 700; }
dim { display: inline; color: #7d8797; font-weight: 400; }
hint { margin-left: auto; color: #5d6675; font-size: 11px; }
sheet { max-width: 640px; margin: 8vh auto; padding: 0 18px; }
card { background: #151a22; border: 1px solid #232833; border-radius: 10px; overflow: hidden; }
card > h2 { margin: 0; padding: 10px 16px; font-size: 13px; color: #a9b3c3;
  background: #171c25; border-bottom: 1px solid #232833; }
kv { display: flex; gap: 14px; justify-content: space-between; padding: 9px 16px;
  border-bottom: 1px solid #1f242e; }
kv::before { content: attr(k); color: #8492a6; }
v { color: #dfe3ea; text-align: right; }
code { background: #0a0d12; border: 1px solid #232833; border-radius: 6px;
  margin: 12px 16px; padding: 10px 12px; color: #9ae6b4;
  white-space: pre-wrap; word-break: break-all; font-size: 12px; }
note { color: #8492a6; padding: 0 16px 14px; font-size: 12px; }
footer { text-align: center; color: #4d5563; font-size: 11px; padding-top: 18px; }
CSS
}
