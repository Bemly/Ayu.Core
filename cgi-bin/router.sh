#!/bin/sh
# router.sh — Ayu.Core CGI entry point
# Receives webhook POSTs, routes to platform handlers, dispatches replies.
# Path: /cgi-bin/router.sh/<platform>
# Or:   /cgi-bin/router.sh?platform=<platform>

# ---- bootstrap ----
_HB="$(dirname "$0")/.."
. "$_HB/lib/core.sh"
. "$_HB/etc/config.sh"
. "$_HB/lib/log.sh"
. "$_HB/lib/http.sh"
. "$_HB/lib/auth.sh"
. "$_HB/lib/dispatch.sh"

# ---- read request ----
_METHOD="${REQUEST_METHOD:-POST}"
_URI="${REQUEST_URI:-}"
_PATH="${PATH_INFO:-}"
_CT="${CONTENT_TYPE:-}"

# read body from stdin
_body="$(dd bs="$CONTENT_LENGTH" 2>/dev/null)"

# request path without the query string (the query carries ?token=)
_path="${_URI%%\?*}"
[ -n "$_PATH" ] && _path="$_PATH"

# ---- auth check ----
# WEBHOOK_SECRET from config.sh; if set, require ?token=<secret> in URL
if ! auth_check "${QUERY_STRING:-}" "${WEBHOOK_SECRET:-}"; then
	# NOTE: never echo the query string back or into the log (it carries the token)
	printf 'Status: 403 Forbidden\r\n'
	printf 'Content-Type: text/plain\r\n\r\n'
	printf '403 Forbidden'
	log_warn "router: auth rejected path=$_path"
	exit 0
fi

# detect platform from URL path
_platform=""
case "$_path" in
	*/qq|*/qq/*) _platform="qq" ;;
	*/telegram|*/telegram/*) _platform="telegram" ;;
	*/discord|*/discord/*) _platform="discord" ;;
	*platform=qq*) _platform="qq" ;;
	*platform=telegram*) _platform="telegram" ;;
	*platform=discord*) _platform="discord" ;;
	*) _platform="qq" ;;  # default
esac

# log the path only — the query string carries ?token=<secret>
log_info "router: $_METHOD $_path platform=$_platform len=${#_body}"

# _err_body <error> — minimal JSON error body (quotes/backslashes stripped)
_err_body() {
	printf '{"ok":false,"error":"%s"}' "$(printf '%s' "$1" | tr -d '"\\' | tr '\n' ' ')"
}

# _status_line <error> — malformed payloads are answered 200 (a retry cannot
# fix them); real processing failures keep 500 so the platform retries.
_status_line() {
	case "$1" in
		*"cannot parse"*|*"empty body"*|*"no body"*) printf 'Status: 200 OK\r\n' ;;
		*) printf 'Status: 500 Internal Server Error\r\n' ;;
	esac
}

# ---- route ----
case "$_platform" in
	qq)
		. "$_HB/adapter/qq/webhook.sh"
		qq_webhook "$_body" || {
			_err="$_ERROR"
			log_err "router: $_err"
			_status_line "$_err"
			printf 'Content-Type: application/json\r\n\r\n'
			_err_body "$_err"
			exit 0
		}
		;;
	telegram)
		. "$_HB/adapter/telegram/webhook.sh"
		tg_webhook "$_body" || {
			_err="$_ERROR"
			log_err "router: $_err"
			_status_line "$_err"
			printf 'Content-Type: application/json\r\n\r\n'
			_err_body "$_err"
			exit 0
		}
		;;
	discord)
		. "$_HB/adapter/discord/webhook.sh"
		dc_webhook_handler "$_body" || {
			_err="$_ERROR"
			log_err "router: $_err"
			_status_line "$_err"
			printf 'Content-Type: application/json\r\n\r\n'
			_err_body "$_err"
			exit 0
		}
		;;
	*)
		printf 'Content-Type: text/plain\r\n\r\n'
		printf 'unknown platform: %s' "$_platform"
		exit 0
		;;
esac

# CGI success response
printf 'Content-Type: application/json\r\n\r\n'
printf '{"status":"ok"}'
exit 0
