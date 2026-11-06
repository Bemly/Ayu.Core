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

# detect platform from URL path (done before auth: the qqbot alternative token
# below must be scoped to the qqbot endpoint)
_platform=""
case "$_path" in
	*/qqbot|*/qqbot/*) _platform="qqbot" ;;
	*/qq|*/qq/*) _platform="qq" ;;
	*/telegram|*/telegram/*) _platform="telegram" ;;
	*/discord|*/discord/*) _platform="discord" ;;
	*platform=qqbot*) _platform="qqbot" ;;
	*platform=qq*) _platform="qq" ;;
	*platform=telegram*) _platform="telegram" ;;
	*platform=discord*) _platform="discord" ;;
	*) _platform="qq" ;;  # default
esac

# ---- auth check ----
# WEBHOOK_SECRET from config.sh; if set, require ?token=<secret> in URL
# QQBOT_WEBHOOK_TOKEN is an optional URL-safe alternative: the QQ open platform
# rewrites/decodes callback URLs aggressively, and WEBHOOK_SECRET may contain
# '#', ';' or '<' which truncate the query string at the edge.
# It is accepted ONLY on the qqbot endpoint — it lives in a URL that the QQ
# platform stores and logs, so it must never unlock qq/telegram/discord.
_auth_ok=0
auth_check "${QUERY_STRING:-}" "${WEBHOOK_SECRET:-}" && _auth_ok=1
if [ "$_auth_ok" -eq 0 ] && [ "$_platform" = "qqbot" ] && [ -n "${QQBOT_WEBHOOK_TOKEN:-}" ]; then
	auth_check "${QUERY_STRING:-}" "$QQBOT_WEBHOOK_TOKEN" && _auth_ok=1
fi
if [ "$_auth_ok" -eq 0 ]; then
	# NOTE: never echo the query string back or into the log (it carries the token)
	printf 'Status: 403 Forbidden\r\n'
	printf 'Content-Type: text/plain\r\n\r\n'
	printf '403 Forbidden'
	log_warn "router: auth rejected path=$_path"
	exit 0
fi

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
	qqbot)
		. "$_HB/adapter/qqbot/webhook.sh"
		# qqbot_webhook runs in a subshell (we need its stdout), so the status
		# line comes back through a file instead of a shared variable.
		QQBOT_STATUS_FILE="/tmp/qqbot-status.$$"
		_qqbot_out="$(qqbot_webhook "$_body" "${HTTP_X_SIGNATURE_ED25519:-}" "${HTTP_X_SIGNATURE_TIMESTAMP:-}" 2>/dev/null)"
		_qqbot_rc=$?
		_qqbot_st="$(cat "$QQBOT_STATUS_FILE" 2>/dev/null)"
		rm -f "$QQBOT_STATUS_FILE"
		printf 'Status: %s\r\n' "${_qqbot_st:-200 OK}"
		printf 'Content-Type: application/json\r\n\r\n'
		if [ $_qqbot_rc -ne 0 ]; then
			log_err "router: ${_ERROR:-qqbot: handler failed}"
			_err_body "${_ERROR:-qqbot: handler failed}"
		else
			printf '%s' "$_qqbot_out"
		fi
		exit 0
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
