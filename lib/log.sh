# log.sh — leveled logging for Ayu.Core
# Source after core.sh

# _LOG_LEVEL: 0=trace, 1=info, 2=warn, 3=err only
# Set in etc/config.sh, default to 1 (info)
_LOG_LEVEL="${_LOG_LEVEL:-1}"
_LOG_DIR="${_LOG_DIR:-$_HB/var/log}"
_LOG_FILE="${_LOG_DIR}/bot.log"
_ERROR_FILE="${_LOG_DIR}/error.log"

mkdir -p "$_LOG_DIR" 2>/dev/null

# _log <level_int> <level_str> <msg>
_log() {
    _lv="$1" _tag="$2"
    if [ "$_lv" -ge "$_LOG_LEVEL" ]; then
        _ts="$(date +%Y-%m-%dT%H:%M:%S)"
        _line="[$_ts] $_tag $3"
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
    _line="[$_ts] ERROR $*"
    printf '%s\n' "$_line" >> "$_LOG_FILE"
    printf '%s\n' "$_line" >> "$_ERROR_FILE"
    printf '%s\n' "$_line" >&2
}
