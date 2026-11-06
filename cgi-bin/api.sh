#!/bin/sh
# api.sh — read-only JSON API backing webui/
# GET /cgi-bin/api.sh?action=status&token=<WEBHOOK_SECRET>
#
# Actions: status | logs | sync | state | config
# Never returns credentials: they are reported as booleans/flags only.

_HB="$(dirname "$0")/.."
. "$_HB/lib/core.sh"
. "$_HB/etc/config.sh"
. "$_HB/lib/log.sh"
. "$_HB/lib/auth.sh"

# ---- auth (same shared secret as the webhooks) ----
if ! auth_check "${QUERY_STRING:-}" "${WEBHOOK_SECRET:-}"; then
	printf 'Status: 403 Forbidden\r\nContent-Type: application/json\r\n\r\n'
	printf '{"error":"forbidden"}'
	log_warn "api: auth rejected action=$(auth_query_param "${QUERY_STRING:-}" action)"
	exit 0
fi

_action="$(auth_query_param "${QUERY_STRING:-}" action)"
_lines="$(auth_query_param "${QUERY_STRING:-}" lines)"
_which="$(auth_query_param "${QUERY_STRING:-}" which)"
case "$_lines" in ''|*[!0-9]*) _lines=80 ;; esac
[ "$_lines" -gt 500 ] && _lines=500

# _kb <dir> — size in KB (0 when missing)
_api_kb() {
	_k="$(du -sk "$1" 2>/dev/null | awk '{print $1}')"
	printf '%s' "${_k:-0}"
}

# _count <dir> — number of files, recursively (msg maps are sharded per chat)
_api_count() {
	_c="$(find "$1" -type f 2>/dev/null | wc -l)"
	printf '%s' "${_c:-0}"
}

# _bool <value> → true/false
_api_bool() {
	if [ -n "$1" ]; then printf 'true'; else printf 'false'; fi
}

# _mask <value> → *** when set, "" when empty
# _api_scrub_url <url> — drop embedded credentials (e.g. .../bot<TOKEN>)
_api_scrub_url() {
	printf '%s' "$1" | sed -E 's#/bot[^/?]*#/bot***#g; s#([?&](token|key|access_token)=)[^&]*#\1***#g'
}

_api_mask() {
	if [ -n "$1" ]; then printf '"***"'; else printf '""'; fi
}

_api_status() {
	_uptime="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)"
	_started="$(cat "$_HB/var/state/started-at" 2>/dev/null)"
	_bot_sz="$(wc -c < "$_LOG_DIR/bot.log" 2>/dev/null)"
	_err_sz="$(wc -c < "$_LOG_DIR/error.log" 2>/dev/null)"
	_cron_sz="$(wc -c < "$_LOG_DIR/cron.log" 2>/dev/null)"
	_maps="$(_api_count "$_STATE_DIR/msg-map")"
	_revs="$(_api_count "$_STATE_DIR/msg-map-rev")"
	# per-platform mapping counts
	_qq_g="$(find "$_STATE_DIR/msg-map" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
	printf '{'
	printf '"uptime_s":%s,' "${_uptime:-0}"
	printf '"started_at":%s,' "$(json_escape "$_started")"
	printf '"host":%s,' "$(json_escape "${BOT_HOST}")"
	printf '"port":%s,' "${BOT_PORT:-0}"
	printf '"platforms":{"qq":%s,"telegram":%s,"discord":%s},' \
		"$(_api_bool "${QQ_API_BASE:-}")" \
		"$(_api_bool "${TG_API_BASE:-}")" \
		"$(_api_bool "${DC_API_BASE:-}")"
	printf '"auth":{"webhook_secret":%s,"tg_api_secret":%s},' \
		"$(_api_bool "${WEBHOOK_SECRET:-}")" \
		"$(_api_bool "${TG_API_SECRET:-}")"
	printf '"logs":{"bot":%s,"error":%s,"cron":%s,"dir_kb":%s},' \
		"${_bot_sz:-0}" "${_err_sz:-0}" "${_cron_sz:-0}" "$(_api_kb "$_LOG_DIR")"
	printf '"state":{"msg_map":%s,"msg_map_rev":%s,"groups":%s,"dir_kb":%s},' \
		"$_maps" "$_revs" "${_qq_g:-0}" "$(_api_kb "$_STATE_DIR")"
	printf '"media":{"cache_kb":%s,"cache_files":%s},' \
		"$(_api_kb /tmp/img)" "$(_api_count /tmp/img)"
	printf '"maintenance":{"last_run":%s}' \
		"$(json_escape "$(grep -o 'maint: .*done.*' "$_LOG_DIR/bot.log" 2>/dev/null | tail -1)")"
	printf '}'
}

_api_logs() {
	case "$_which" in
		error) _f="$_LOG_DIR/error.log" ;;
		cron)  _f="$_LOG_DIR/cron.log" ;;
		*)     _which="bot"; _f="$_LOG_DIR/bot.log" ;;
	esac
	if [ ! -f "$_f" ]; then
		printf '{"which":%s,"lines":[]}' "$_which"
		return 0
	fi
	printf '{"which":%s,"total":%s,"lines":[' "$_which" "$(wc -l < "$_f" 2>/dev/null || echo 0)"
	_first=1
	tail -n "$_lines" "$_f" 2>/dev/null | while IFS= read -r _l; do
		if [ "$_first" = "1" ]; then _first=0; else printf ','; fi
		printf '%s' "$(json_escape "$_l")"
	done
	printf ']}'
}

_api_sync() {
	printf '{"pairs":['
	_first=1
	[ -f "${_SYNC_CONF:-$_HB/etc/sync.conf}" ] && while IFS= read -r _line; do
		case "$_line" in \#*|"") continue ;; esac
		_s="${_line%%=*}" _t="${_line#*=}"
		[ -z "$_s" ] && continue
		if [ "$_first" = "1" ]; then _first=0; else printf ','; fi
		printf '{"source":%s,"target":%s,"targets":[' "$(json_escape "$_s")" "$(json_escape "$_t")"
		_tf=1
		for _one in $(printf '%s' "$_t" | tr ',' ' '); do
			if [ "$_tf" = "1" ]; then _tf=0; else printf ','; fi
			printf "%s" "$(json_escape "$_one")"
		done
		printf ']}'
	done < "${_SYNC_CONF:-$_HB/etc/sync.conf}"
	printf ']}'
}

_api_config() {
	printf '{'
	printf '"bot_host":%s,"bot_port":%s,' "$(json_escape "$BOT_HOST")" "${BOT_PORT:-0}"
	printf '"qq_api_base":%s,' "$(json_escape "$(_api_scrub_url "$QQ_API_BASE")")"
	printf '"tg_api_base":%s,' "$(json_escape "$(_api_scrub_url "$TG_API_BASE")")"
	printf '"dc_api_base":%s,' "$(json_escape "$(_api_scrub_url "$DC_API_BASE")")"
	printf '"token_masked":%s,' "$(_api_mask "${TG_TOKEN:-}")"
	printf '"max_file_size":%s,' "${_SYNC_MAX_FILE_SIZE:-20000000}"
	printf '"log_level":%s' "${_LOG_LEVEL:-1}"
	printf '}'
}

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
case "$_action" in
	status) _api_status ;;
	logs)   _api_logs ;;
	sync)   _api_sync ;;
	config) _api_config ;;
	""|state) _api_status ;;
	*)
		printf 'Status: 400 Bad Request\r\nContent-Type: application/json\r\n\r\n'
		printf '{"error":"unknown action"}'
		exit 0
		;;
esac
exit 0
