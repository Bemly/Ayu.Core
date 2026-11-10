#!/bin/sh
# api.sh — read-only JSON API for scripts and the XML dashboard
# GET /cgi-bin/api.sh?action=status&token=<WEBHOOK_SECRET>
#
# Actions: status | logs | sync | state | config
# Never returns credentials: they are reported as booleans/flags only.

_HB="$(dirname "$0")/.."
. "$_HB/lib/core.sh"
. "$_HB/etc/config.sh"
. "$_HB/lib/log.sh"
. "$_HB/lib/auth.sh"
. "$_HB/lib/stats.sh"   # gauges shared with the XML dashboard (cgi-bin/web.sh)

# ---- auth (same shared secret as the webhooks) ----
# The token is read from the X-Ayu-Token header when present: a secret in the
# query string is written to the httpd access log and to every reverse-proxy
# log it passes. ?token= stays supported for old bookmarks and for curl one-
# liners, so nothing breaks — but the webui now sends the header.
_auth_qs="${QUERY_STRING:-}"
if [ -n "${HTTP_X_AYU_TOKEN:-}" ]; then
	_auth_qs="token=$(url_encode "$HTTP_X_AYU_TOKEN")"
fi
if auth_misconfigured; then
	printf 'Status: 503 Service Unavailable\r\nContent-Type: application/json\r\n\r\n'
	printf '{"error":"misconfigured"}'
	log_err "api: AYU_ENV=${AYU_ENV:-?} without WEBHOOK_SECRET — refusing"
	exit 0
fi
if ! auth_check "$_auth_qs" "${WEBHOOK_SECRET:-}"; then
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

# Sizes and counts live in lib/stats.sh: the XML dashboard prints the same
# gauges, and duplicating the /tmp caching here would let the JSON and the
# page disagree. See stats_kb / stats_count.

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
	printf '{'
	printf '"uptime_s":%s,' "$(stats_uptime)"
	printf '"started_at":%s,' "$(json_escape "$(stats_started_at)")"
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
		"$(stats_log_bytes bot)" "$(stats_log_bytes error)" "$(stats_log_bytes cron)" \
		"$(stats_kb "$_LOG_DIR")"
	printf '"state":{"msg_map":%s,"msg_map_rev":%s,"groups":%s,"dir_kb":%s},' \
		"$(stats_count "$_STATE_DIR/msg-map")" \
		"$(stats_count "$_STATE_DIR/msg-map-rev")" \
		"$(stats_groups)" "$(stats_kb "$_STATE_DIR")"
	printf '"media":{"cache_kb":%s,"cache_files":%s},' \
		"$(stats_kb /tmp/img)" "$(stats_count /tmp/img)"
	printf '"maintenance":{"last_run":%s},' \
		"$(json_escape "$(stats_maint_last)")"
	# events dropped by router.sh (handler failures). Non-zero means platforms
	# are being retried into a wall — visible here instead of only in the log.
	printf '"events":{"dropped":%s}' "$(stats_dropped)"
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
	_sp="$(stats_sync_pairs)"
	if [ -n "$_sp" ]; then
		_sp_tab="$(printf '\t')"
		printf '%s\n' "$_sp" | while IFS="$_sp_tab" read -r _s _t; do
			if [ "$_first" = "1" ]; then _first=0; else printf ','; fi
			printf '{"source":%s,"target":%s,"targets":[' "$(json_escape "$_s")" "$(json_escape "$_t")"
			_tf=1
			for _one in $(printf '%s' "$_t" | tr ',' ' '); do
				if [ "$_tf" = "1" ]; then _tf=0; else printf ','; fi
				printf "%s" "$(json_escape "$_one")"
			done
			printf ']}'
		done
	fi
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
