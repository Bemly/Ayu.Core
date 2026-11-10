# stats.sh — read-only gauges for the dashboard
#
# Single source of truth for every number the dashboard shows. Nothing here
# formats output: callers decide between JSON (cgi-bin/api.sh) and HTML
# (cgi-bin/web.sh), so a gauge is never computed twice and the two views can
# never disagree.
#
# Source after core.sh and etc/config.sh. Every function prints exactly one
# value and returns 0; missing data prints 0 (or an empty string), never an
# error. Never prints a credential.

# --- small helpers -------------------------------------------------------

# _stats_cache <kind> <dir> → cache path in /tmp (regenerable, never backed up)
_stats_cache() {
	printf '/tmp/ayu-%s.%s' "$1" "$(printf '%s' "$2" | tr '/ ' '__')"
}

# _stats_fresh <cache-file> <minutes> → 0 when the cache is younger than ttl
# mtime is the timestamp, so no separate bookkeeping file is needed.
_stats_fresh() {
	[ -f "$1" ] && [ -n "$(find "$1" -mmin -"$2" 2>/dev/null)" ]
}

# --- storage gauges ------------------------------------------------------

# stats_kb <dir> — on-disk size in KB, cached 60 s
# The dashboard refreshes every 15 s and `du` walks the whole tree, so an
# uncached call per poll would spin the disk for nothing. A minute of
# staleness is fine: this is a gauge, not a control value.
stats_kb() {
	_st_c="$(_stats_cache kb "$1")"
	if _stats_fresh "$_st_c" 1; then
		cat "$_st_c"
		return 0
	fi
	_st_v="$(du -sk "$1" 2>/dev/null | awk '{print $1}')"
	printf '%s' "${_st_v:-0}" > "$_st_c" 2>/dev/null
	printf '%s' "${_st_v:-0}"
}

# stats_count <dir> — files below dir, recursive, cached 60 s
# msg-map holds ~16k sharded files; a full find on every poll is pure waste.
stats_count() {
	_st_c="$(_stats_cache count "$1")"
	if _stats_fresh "$_st_c" 1; then
		cat "$_st_c"
		return 0
	fi
	_st_v="$(find "$1" -type f 2>/dev/null | wc -l)"
	printf '%s' "${_st_v:-0}" > "$_st_c" 2>/dev/null
	printf '%s' "${_st_v:-0}"
}

# stats_groups — number of chats with a message map (one dir per chat)
stats_groups() {
	_st_v="$(find "$_STATE_DIR/msg-map" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
	printf '%s' "${_st_v:-0}"
}

# --- process gauges ------------------------------------------------------

# stats_uptime — container uptime in seconds (from /proc, not from a file)
stats_uptime() {
	_st_v="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)"
	printf '%s' "${_st_v:-0}"
}

# stats_started_at — wall-clock start time written by lib/log.sh
stats_started_at() {
	cat "$_HB/var/state/started-at" 2>/dev/null
}

# stats_log_bytes <bot|error|cron> — current size of one log file
stats_log_bytes() {
	case "$1" in
		error|bot|cron) _st_f="$_LOG_DIR/$1.log" ;;
		*) printf '0'; return 0 ;;
	esac
	_st_v="$(wc -c < "$_st_f" 2>/dev/null | tr -d ' ')"
	case "$_st_v" in ''|*[!0-9]*) _st_v=0 ;; esac
	printf '%s' "$_st_v"
}

# stats_dropped — events dropped by router.sh (non-zero = handlers failing)
stats_dropped() {
	_st_v="$(wc -l < "$_STATE_DIR/failures" 2>/dev/null | tr -d ' ')"
	case "$_st_v" in ''|*[!0-9]*) _st_v=0 ;; esac
	printf '%s' "$_st_v"
}

# stats_maint_last — last maintenance marker from bot.log ("" when never run)
stats_maint_last() {
	grep -o 'maint: .*done.*' "$_LOG_DIR/bot.log" 2>/dev/null | tail -1
}

# --- config gauge --------------------------------------------------------

# stats_sync_pairs — "source<TAB>target1,target2" per line of sync.conf
# Prints nothing when there is no conf or no valid pair; callers decide
# between an empty table and an empty JSON array.
stats_sync_pairs() {
	_st_conf="${_SYNC_CONF:-$_HB/etc/sync.conf}"
	[ -f "$_st_conf" ] || return 0
	while IFS= read -r _st_line; do
		case "$_st_line" in \#*|"") continue ;; esac
		_st_src="${_st_line%%=*}"
		_st_tgt="${_st_line#*=}"
		[ -n "$_st_src" ] || continue
		printf '%s\t%s\n' "$_st_src" "$_st_tgt"
	done < "$_st_conf"
}
