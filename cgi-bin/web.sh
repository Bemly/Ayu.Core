#!/bin/sh
# web.sh — dashboard served as XML + CSS (no HTML, no JavaScript)
#
#   GET  /cgi-bin/web.sh                     the panel (all sections on one page)
#   GET  /cgi-bin/web.sh?page=overview|sync|logs|config   highlight one section
#   GET  /cgi-bin/web.sh?logs=bot|error|cron&lines=N      pick the log tail
#   GET  /cgi-bin/web.sh?css=1               the panel stylesheet (text/css)
#   GET  /cgi-bin/web.sh?css=gate            the gate stylesheet (text/css)
#   POST /cgi-bin/web.sh  token=<secret>     verify, Set-Cookie, 303
#   GET  /cgi-bin/web.sh?logout=1            drop the cookie
#
# Why XML and not HTML: the document is data plus one stylesheet reference. The
# browser gets `text/xml` and a `<?xml-stylesheet type="text/css"?>` PI, and the
# whole presentation is one CSS file this same CGI generates. Nothing is
# hydrated, nothing is scripted, and the panel still renders with JS disabled.
#
# What XML costs us — measured in Chromium, not assumed:
#   * `.class` selectors never match in an XML document, so the sheet is built
#     from element names and attribute selectors only (see lib/render.sh).
#   * <a> is not a link and <input> is not a control. There is no way to submit
#     a form, so sign-in happens out of band (curl POST, see the gate text) and
#     navigation is by URL. The only in-page writable channels are the pads,
#     which fire one CSS background-image request on mouse-down (cgi-bin/act.sh)
#     and are limited to pause/resume of this page's own auto-refresh.
#   * auto-refresh cannot use <meta http-equiv>: it is an HTTP `Refresh:` header.
#
# Auth is unchanged from the HTML version: the token only ever travels in a POST
# body, success sets ayu=<sha256(token)> as an HttpOnly cookie, and the digest is
# what gets compared, so the plaintext secret never sits in the browser.

_HB="$(cd "$(dirname "$0")/.." && pwd)"
. "$_HB/lib/core.sh"
. "$_HB/etc/config.sh"
. "$_HB/lib/log.sh"
. "$_HB/lib/auth.sh"
. "$_HB/lib/stats.sh"
. "$_HB/lib/render.sh"

_QS="${QUERY_STRING:-}"
_LOG_LINES_DEFAULT=40
_NONCE_TTL=180

_web_sec="${WEBHOOK_SECRET:-}"
_web_hash=""
[ -n "$_web_sec" ] && _web_hash="$(printf '%s' "$_web_sec" | sha256sum | awk '{print $1}')"

_web_ck="$(printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' | sed -n 's/^[[:space:]]*ayu=//p' | head -1)"

_web_authed() {
	[ -z "$_web_sec" ] && return 0
	[ "$_web_ck" = "$_web_hash" ] && return 0
	return 1
}

# --- nonce ring ----------------------------------------------------------
# act.sh accepts a nonce that is (a) in this ring and (b) younger than
# _NONCE_TTL. The ring is capped so a long-lived page cannot grow the file, and
# old entries are pruned on every write.
_web_nonce_file="$_STATE_DIR/web-nonce"

_web_nonce_new() {
	_n="$(head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
	[ -n "$_n" ] || _n="$(date +%s)$$"
	_now="$(date +%s)"
	{
		printf '%s %s\n' "$_n" "$_now"
		# The `if` matters: `[ -f ] && awk` as the block's last command would
		# exit non-zero on the very first call and skip the rename below, which
		# leaves the ring file uncreated and every command URL dead.
		if [ -f "$_web_nonce_file" ]; then
			awk -v t="$_now" -v ttl="$_NONCE_TTL" \
				'NF==2 && $2+0 > t-ttl' "$_web_nonce_file" 2>/dev/null | tail -19
		fi
	} > "$_web_nonce_file.tmp" 2>/dev/null && mv "$_web_nonce_file.tmp" "$_web_nonce_file" 2>/dev/null
	printf '%s' "$_n"
}

# --- response headers ----------------------------------------------------

_web_type() {
	printf 'Content-Type: %s; charset=utf-8\r\n' "${1:-text/xml}"
	printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
	printf 'X-Frame-Options: DENY\r\n'
	printf 'X-Content-Type-Options: nosniff\r\n'
	printf 'Referrer-Policy: no-referrer\r\n'
}

# _web_hdr [refresh-seconds] [refresh-url]
_web_hdr() {
	_web_type text/xml
	if [ -n "${1:-}" ]; then
		printf 'Refresh: %s; url=%s\r\n' "$1" "${2:-/cgi-bin/web.sh}"
	fi
	printf '\r\n'
}

# --- stylesheet ----------------------------------------------------------

if [ "$(auth_query_param "$_QS" css)" != "" ]; then
	case "$(auth_query_param "$_QS" css)" in
		gate)
			_web_type text/css
			printf '\r\n'
			render_gate_css
			exit 0
			;;
		*)
			# The panel sheet embeds a command nonce, so it is as sensitive as
			# the panel itself: refuse to hand it to an unauthenticated caller.
			if auth_misconfigured || ! _web_authed; then
				_web_type text/css
				printf '\r\n'
				printf '/* refused */\npanel { display: block; }\n'
				exit 0
			fi
			_web_type text/css
			printf '\r\n'
			render_css "$(_web_nonce_new)"
			exit 0
			;;
	esac
fi

# --- logout --------------------------------------------------------------

if [ "$(auth_query_param "$_QS" logout)" = "1" ]; then
	printf 'Status: 303 See Other\r\nLocation: /cgi-bin/web.sh\r\n'
	printf 'Set-Cookie: ayu=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict\r\n\r\n'
	exit 0
fi

# --- login ---------------------------------------------------------------

_web_err=""
if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
	# The client is curl, not a form: same one-field body, same cap. CONTENT_LENGTH
	# is attacker-controlled, so the read is bounded before it starts.
	_web_len="${CONTENT_LENGTH:-0}"
	case "$_web_len" in ''|*[!0-9]*) _web_len=0 ;; esac
	[ "$_web_len" -gt 2048 ] && _web_len=2048
	_web_body=""
	[ "$_web_len" -gt 0 ] && _web_body="$(head -c "$_web_len" 2>/dev/null)"
	_web_tok="$(url_decode "$(auth_query_param "$_web_body" token)")"
	if [ -n "$_web_sec" ] && [ "$_web_tok" = "$_web_sec" ]; then
		_web_dst="$(auth_query_param "$_QS" page)"
		case "$_web_dst" in overview|sync|logs|config) ;; *) _web_dst=all ;; esac
		printf 'Status: 303 See Other\r\nLocation: /cgi-bin/web.sh?page=%s\r\n' "$_web_dst"
		printf 'Set-Cookie: ayu=%s; Path=/; HttpOnly; SameSite=Strict\r\n\r\n' "$_web_hash"
		log_info "web: session opened"
		exit 0
	fi
	_web_err="密钥错误"
	log_warn "web: rejected a login attempt"
fi

# --- refusal / gate documents -------------------------------------------

# Fail closed when a prod tree lost its secret: an open dashboard is worse than
# an error page.
if auth_misconfigured; then
	printf 'Status: 503 Service Unavailable\r\n'
	_web_hdr
	render_head "Ayu · 拒绝服务" "0"
	printf '<sheet><card><h2>面板拒绝提供服务</h2>\n'
	printf '<kv k="原因"><v>WEBHOOK_SECRET 未配置</v></kv>\n'
	printf '<kv k="运行环境"><v>%s</v></kv>\n' "$(render_esc "${AYU_ENV:-?}")"
	printf '<note>生产环境必须在 etc/config.prod.sh 中配置 WEBHOOK_SECRET。'\
'缺省密钥等于把控制面板暴露给任何能访问端口的人，因此这里选择直接拒绝。</note>\n'
	printf '</card></sheet>\n'
	render_foot "Ayu.Core · xml dashboard"
	log_err "web: AYU_ENV=${AYU_ENV:-?} without WEBHOOK_SECRET — refusing"
	exit 0
fi

_web_gate() {
	_web_hdr 30 "/cgi-bin/web.sh"
	printf '<?xml version="1.0" encoding="UTF-8"?>\n'
	printf '<?xml-stylesheet type="text/css" href="/cgi-bin/web.sh?css=gate"?>\n'
	printf '<panel>\n<bar><brand>Ayu <dim>Console</dim></brand>'
	printf '<hint>XML + CSS · 无 JavaScript</hint></bar>\n'
	printf '<sheet><card><h2>需要登录</h2>\n'
	printf '<kv k="状态"><v>未持有有效的 ayu Cookie</v></kv>\n'
	if [ -n "$_web_err" ]; then
		printf '<kv k="上一次尝试"><v>%s</v></kv>\n' "$(render_esc "$_web_err")"
	fi
	printf '<note>这个面板不是 HTML，也没有表单控件：XML 文档里的 input 不是输入框，'\
'浏览器不会给它任何交互行为。所以登录用一条命令完成，密钥只走 POST body，'\
'不会进入地址栏或访问日志。</note>\n'
	printf '<code>curl -s -X POST -d "token=$WEBHOOK_SECRET" \\\n'\
'  http://%s:%s/cgi-bin/web.sh -c ayu.txt -o /dev/null\n'\
'# 然后把 ayu.txt 里的 ayu Cookie 交给浏览器，或直接用 curl 读取面板：\n'\
'curl -s -b ayu.txt http://%s:%s/cgi-bin/web.sh</code>\n' \
		"$(render_esc "${BOT_HOST:-127.0.0.1}")" "$(render_esc "${BOT_PORT:-6160}")" \
		"$(render_esc "${BOT_HOST:-127.0.0.1}")" "$(render_esc "${BOT_PORT:-6160}")"
	printf '<note>本页每 30 秒自动重试；拿到 Cookie 后无需操作，刷新即进入。</note>\n'
	printf '</card></sheet>\n'
	render_foot "Ayu.Core · xml dashboard"
}

if ! _web_authed; then
	_web_gate
	exit 0
fi

# --- panel ---------------------------------------------------------------

_web_page="$(auth_query_param "$_QS" page)"
case "$_web_page" in overview|sync|logs|config) ;; *) _web_page=all ;; esac

_web_which="$(auth_query_param "$_QS" logs)"
case "$_web_which" in bot|error|cron) ;; *) _web_which=bot ;; esac

_web_lines="$(auth_query_param "$_QS" lines)"
case "$_web_lines" in ''|*[!0-9]*) _web_lines=$_LOG_LINES_DEFAULT ;; esac
[ "$_web_lines" -gt 300 ] && _web_lines=300

# Auto-refresh is an HTTP header. A paused panel still refreshes, just slowly —
# otherwise the resume pad could never be observed from the browser.
_paused=0
[ -f "$_STATE_DIR/web-paused" ] && _paused=1
_self_qs="page=$_web_page&logs=$_web_which&lines=$_web_lines"
if [ "$_paused" = "1" ]; then
	_web_hdr 30 "/cgi-bin/web.sh?$_self_qs"
else
	_web_hdr 5 "/cgi-bin/web.sh?$_self_qs"
fi

_nonce="$(_web_nonce_new)"
render_head "Ayu · 控制台" "$_nonce"
render_tabs "$_web_page"
render_pads "$_nonce" "$([ "$_paused" = "1" ] && printf paused || printf running)"

# --- 3D scene: one block per headline gauge ------------------------------

_qq_tone=off; [ -n "${QQ_API_BASE:-}" ] && _qq_tone=ok
_tg_tone=off; [ -n "${TG_API_BASE:-}" ] && _tg_tone=ok
_dc_tone=off; [ -n "${DC_API_BASE:-}" ] && _dc_tone=ok
_drop_tone=ok; [ "$(stats_dropped)" != "0" ] && _drop_tone=err
_sec_tone=off; [ -n "$_web_sec" ] && _sec_tone=ok

printf '<scene>\n'
render_cube "运行时长" "$(render_duration "$(stats_uptime)")" ok
render_cube "QQ 官方 API" "$([ "$_qq_tone" = ok ] && printf 在线 || printf 未配置)" "$_qq_tone"
render_cube "Telegram" "$([ "$_tg_tone" = ok ] && printf 在线 || printf 未配置)" "$_tg_tone"
render_cube "Discord" "$([ "$_dc_tone" = ok ] && printf 在线 || printf 未配置)" "$_dc_tone"
render_cube "丢弃事件" "$(stats_dropped)" "$_drop_tone"
render_cube "面板密钥" "$([ "$_sec_tone" = ok ] && printf 已配置 || printf 未配置)" "$_sec_tone"
printf '</scene>\n'

printf '<sheet>\n'

# --- headline numbers ----------------------------------------------------

printf '<grid>\n'
render_stat "监听地址" "${BOT_HOST}:${BOT_PORT:-0}"
render_stat "消息映射" "$(stats_count "$_STATE_DIR/msg-map") 条"
render_stat "会话数" "$(stats_groups)"
render_stat "state 占用" "$(render_kb "$(stats_kb "$_STATE_DIR")")"
render_stat "日志占用" "$(render_kb "$(stats_kb "$_LOG_DIR")")"
render_stat "运行环境" "${AYU_ENV:-dev}"
printf '</grid>\n'

# --- storage -------------------------------------------------------------

render_card_open "存储"
render_kv "消息映射 (msg-map)" "$(printf '%s 条 / %s 个会话' \
	"$(stats_count "$_STATE_DIR/msg-map")" "$(stats_groups)")"
render_kv "反向映射 (msg-map-rev)" "$(printf '%s 条' \
	"$(stats_count "$_STATE_DIR/msg-map-rev")")"
render_kv "state 目录" "$(render_kb "$(stats_kb "$_STATE_DIR")")"
render_kv "转发媒体缓存 (/tmp/img)" "$(printf '%s 个 / %s' \
	"$(stats_count /tmp/img)" "$(render_kb "$(stats_kb /tmp/img)")")"
render_kv "日志体积" "$(printf 'bot %s · error %s · cron %s' \
	"$(render_bytes "$(stats_log_bytes bot)")" \
	"$(render_bytes "$(stats_log_bytes error)")" \
	"$(render_bytes "$(stats_log_bytes cron)")")"
render_kv "自动刷新" "$([ "$_paused" = "1" ] && printf '已暂停（30 秒慢速兜底）' || printf '5 秒')"
render_card_close

# --- forwarding map ------------------------------------------------------

_st_tab="$(printf '\t')"
_n_pairs="$(stats_sync_pairs | wc -l | tr -d ' ')"
render_card_open "转发映射 · ${_n_pairs} 组"
if [ "$_n_pairs" = "0" ]; then
	render_kv "sync.conf" "没有有效映射"
else
	stats_sync_pairs | while IFS="$_st_tab" read -r _ps _pt; do
		render_kv "$_ps" "$(printf '%s' "$_pt" | tr ',' ' ')"
	done
fi
render_card_close

# --- log tail ------------------------------------------------------------

render_card_open "日志 · ${_web_which}.log · 末 ${_web_lines} 行"
printf '<sec>?logs=bot | error | cron · ?lines=1-300</sec>\n'
printf '<log>\n'
if [ -f "$_LOG_DIR/$_web_which.log" ]; then
	tail -n "$_web_lines" "$_LOG_DIR/$_web_which.log" 2>/dev/null | while IFS= read -r _l; do
		render_line "$_l"
	done
else
	printf '<line tone="muted">（日志文件不存在）</line>\n'
fi
printf '</log>\n'
render_card_close

# --- config --------------------------------------------------------------

render_card_open "运行配置"
render_kv "监听地址" "${BOT_HOST}:${BOT_PORT:-0}"
render_kv "QQ API" "${QQ_API_BASE:-'-'}"
render_kv "Telegram API" "${TG_API_BASE:-'-'}"
render_kv "Discord API" "${DC_API_BASE:-'-'}"
render_kv "webhook 密钥" "$(render_flag "$_web_sec")"
render_kv "Telegram 密钥" "$(render_flag "${TG_API_SECRET:-}")"
render_kv "Telegram Token" "$(render_flag "${TG_TOKEN:-}")"
render_kv "转发单文件上限" "$(render_bytes "${_SYNC_MAX_FILE_SIZE:-0}")"
render_kv "日志级别" "${_LOG_LEVEL:-1}"
render_kv "运行环境" "${AYU_ENV:-dev}"
render_kv "启动时间" "$(stats_started_at)"
render_kv "最近维护" "$(stats_maint_last)"
render_card_close

printf '</sheet>\n'
render_foot "Ayu.Core · xml dashboard · 5s 自动刷新 · 无 JavaScript"
exit 0
