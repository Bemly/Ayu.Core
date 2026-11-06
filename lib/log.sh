# log.sh — leveled logging for Ayu.Core
# Source after core.sh

# _LOG_LEVEL: 0=trace, 1=info, 2=warn, 3=err only
# Set in etc/config.sh, default to 1 (info)
_LOG_LEVEL="${_LOG_LEVEL:-1}"
_LOG_DIR="${_LOG_DIR:-$_HB/var/log}"
_LOG_FILE="${_LOG_DIR}/bot.log"
_ERROR_FILE="${_LOG_DIR}/error.log"

mkdir -p "$_LOG_DIR" 2>/dev/null

# _log_scrub <text> → text with credentials masked
# Every line written to disk passes through the redaction path, so a secret that
# leaks into a log message (callback URL, API error body, traceback) never lands
# in bot.log/error.log in clear text.
_log_scrub() {
	printf '%s' "$1" | sed -E \
		-e 's/([?&](token|rkey|access_token|refresh_token|api_key|key|secret|password|passwd|pwd|sign|signature|sig)=)[^&"[:space:]]*/\1***/g' \
		-e 's#(https?://[^/:[:space:]]+/file/bot)[^/[:space:]]+#\1***#g' \
		-e 's/(bot[0-9][0-9][0-9][0-9][0-9][0-9]*:)[A-Za-z0-9_-][A-Za-z0-9_-]*/\1***/g' \
		-e 's/((Bot|Bearer)[[:space:]]+)[A-Za-z0-9._:-]+/\1***/g' \
		-e 's/("?(WEBHOOK_SECRET|TG_TOKEN|TG_API_SECRET|DC_TOKEN|QQ_TOKEN|BOT_TOKEN|webhook_secret|token|secret|password)"?[[:space:]]*[:=][[:space:]]*"?)[^",}[:space:]]*/\1***/g'
}

# _log_redact <text> → scrub only when it looks like it may carry a credential
_log_redact() {
	case "$1" in
		*token=*|*TOKEN=*|*secret*|*SECRET*|*rkey=*|*"Bot "*|*"Bearer "*|*bot[0-9]*) _log_scrub "$1" ;;
		*) printf '%s' "$1" ;;
	esac
}

# _log <level_int> <level_str> <msg>
_log() {
	_lv="$1" _tag="$2"
	if [ "$_lv" -ge "$_LOG_LEVEL" ]; then
		_ts="$(date +%Y-%m-%dT%H:%M:%S)"
		_line="[$_ts] $_tag $(_log_redact "$3")"
		printf '%s\n' "$_line" >> "$_LOG_FILE"
		printf '%s\n' "$_line" >&2
	fi
}

log_trace()  { _log 0 TRACE "$@"; }
log_debug()  { _log 0 DEBUG "$@"; }
log_info()   { _log 1 INFO  "$@"; }
log_warn()   { _log 2 WARN  "$@"; }

log_err() {
	_ts="$(date +%Y-%m-%dT%H:%M:%S)"
	_line="[$_ts] ERROR $(_log_redact "$*")"
	printf '%s\n' "$_line" >> "$_LOG_FILE"
	printf '%s\n' "$_line" >> "$_ERROR_FILE"
	printf '%s\n' "$_line" >&2
}
