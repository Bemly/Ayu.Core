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
. "$_HB/lib/dispatch.sh"

# ---- read request ----
_METHOD="${REQUEST_METHOD:-POST}"
_URI="${REQUEST_URI:-}"
_PATH="${PATH_INFO:-}"
_CT="${CONTENT_TYPE:-}"

# read body from stdin
_body="$(dd bs="$CONTENT_LENGTH" 2>/dev/null)"

# ---- auth check ----
# WEBHOOK_SECRET from config.sh; if set, require ?token=<secret> in URL
if [ -n "${WEBHOOK_SECRET:-}" ]; then
	_token="$(printf '%s' "${QUERY_STRING:-}" | sed 's/.*token=//' | sed 's/&.*//')"
	_token="$(url_decode "$_token")"
	if [ "$_token" != "$WEBHOOK_SECRET" ]; then
		printf 'Content-Type: text/plain\r\n\r\n'
		printf '403 Forbidden'
		exit 0
	fi
fi

# detect platform from URL path (strip query string first)
_platform=""
_path="${_URI%%\?*}"
case "$_path" in
	*/qq|*/qq/*) _platform="qq" ;;
	*/telegram|*/telegram/*) _platform="telegram" ;;
	*/discord|*/discord/*) _platform="discord" ;;
	*platform=qq*) _platform="qq" ;;
	*platform=telegram*) _platform="telegram" ;;
	*platform=discord*) _platform="discord" ;;
	*) _platform="qq" ;;  # default
esac

_JSON_ELINE="$LINENO"

log_info "router: $_METHOD $_URI platform=$_platform len=${#_body}"

# ---- route ----
case "$_platform" in
	qq)
		. "$_HB/adapter/qq/webhook.sh"
		qq_webhook "$_body" || {
			_err="$_ERROR"
			log_err "router: $_err"
			printf 'Content-Type: application/json\r\n\r\n'
			printf '{"status":"error","message":"%s"}' "$_err"
			exit 0
		}
		;;
	telegram)
		. "$_HB/adapter/telegram/webhook.sh"
		tg_webhook "$_body" || {
			_err="$_ERROR"
			log_err "router: $_err"
			printf 'Content-Type: application/json\r\n\r\n'
			printf '{"status":"error","message":"%s"}' "$_err"
			exit 0
		}
		;;
	discord)
		. "$_HB/adapter/discord/webhook.sh"
		dc_webhook_handler "$_body" || {
			_err="$_ERROR"
			log_err "router: $_err"
			printf 'Content-Type: application/json\r\n\r\n'
			printf '{"status":"error","message":"%s"}' "$_err"
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
