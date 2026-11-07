# clean.sh — housekeeping: log rotation + stale temp cleanup
# Called from cgi-bin/start.sh (boot) and etc/crontab (daily).
#
# Never touches:
#   /tmp/img (forwarded media cache), chat text/image files, dc-cursor.
# Removes:
#   rotated/oversized logs, abandoned /tmp scratch files, and *expired message
#   map entries* in var/state/msg-map{,-rev} (see maint_trim_state).
# The media cache (/tmp/img) is measured for reporting only, never pruned.
#
# Message maps are the QQ<->TG/DC routing table. Entries only matter while the
# conversation is recent (reply-quoting / loop prevention), so they are trimmed
# by age and by per-conversation count. Tunables (env or etc/config.sh):
#   MAINT_STATE_KEEP_DAYS   keep entries younger than N days   (default 30)
#   MAINT_STATE_KEEP_ITEMS  hard cap per conversation dir       (default 5000)
#   MAINT_STATE_MIN_ITEMS   never trim a dir below this         (default 200)
#   MAINT_STATE_DRY         1 = report only, delete nothing      (default 0)

[ -z "${_HB:-}" ] && _HB="$(cd "$(dirname "$0")/../.." && pwd)"

_MAINT_LOG_DIR="${_LOG_DIR:-$_HB/var/log}"
_MAINT_TMP_IMG="/tmp/img"

# maint_rotate <file> <max_bytes> <keep_archives>
# Rotates in place: file → file.1 → file.2 ... oldest dropped.
maint_rotate() {
	_mr_file="$1" _mr_max="${2:-5242880}" _mr_keep="${3:-2}"
	[ -f "$_mr_file" ] || return 0
	_mr_sz="$(wc -c < "$_mr_file" 2>/dev/null)" || _mr_sz=0
	[ "${_mr_sz:-0}" -lt "$_mr_max" ] && return 0
	_mr_i="$_mr_keep"
	while [ "$_mr_i" -gt 1 ]; do
		_mr_prev=$((_mr_i - 1))
		[ -f "$_mr_file.$_mr_prev" ] && mv "$_mr_file.$_mr_prev" "$_mr_file.$_mr_i"
		_mr_i="$_mr_prev"
	done
	mv "$_mr_file" "$_mr_file.1"
	: > "$_mr_file"
	chmod 640 "$_mr_file" 2>/dev/null
	printf '%s maint: rotated %s (%s bytes)\n' "$(date +%FT%T)" "$_mr_file" "$_mr_sz" >> "$_MAINT_LOG_DIR/bot.log"
}

# maint_clean_tmp [minutes] — drop abandoned request/upload scratch files
maint_clean_tmp() {
	_mc_min="${1:-60}"
	# request bodies, fifos, ssl wrappers, multipart bodies, API response temps
	find /tmp -maxdepth 1 -type f \
		\( -name 'ayu-*' -o -name 'tg-up-*' -o -name 'tg-api.*' -o -name 'dc-*resp*' \
		-o -name 'qq-up-err.*' -o -name 'dc-out.*' -o -name 'dc-api-resp.*' \) \
		-mmin +"$_mc_min" -exec rm -f {} + 2>/dev/null
	find /tmp -maxdepth 1 -type p -name 'ayu-fifo.*' -mmin +5 -exec rm -f {} + 2>/dev/null
}

# maint_trim_state [days] [keep_items] [dry] — prune expired routing entries
# Keeps the newest MAINT_STATE_KEEP_ITEMS per conversation and drops anything
# older than MAINT_STATE_KEEP_DAYS. dc-cursor is never touched.
maint_trim_state() {
	_mt_days="${1:-${MAINT_STATE_KEEP_DAYS:-30}}"
	_mt_keep="${2:-${MAINT_STATE_KEEP_ITEMS:-5000}}"
	_mt_min="${MAINT_STATE_MIN_ITEMS:-200}"
	_mt_dry="${3:-${MAINT_STATE_DRY:-0}}"
	_mt_del=0
	_mt_trunc=0
	for _mt_base in msg-map msg-map-rev; do
		_mt_root="$_HB/var/state/$_mt_base"
		[ -d "$_mt_root" ] || continue
		for _mt_dir in "$_mt_root"/*; do
			[ -d "$_mt_dir" ] || continue
			# 1) age-based: entries older than N days are dead weight. Nothing
			# written in the last 10 minutes is touched: bot and maintainer run
			# unsynchronised, and a just-written mapping must not vanish under
			# the process that is still using it.
			if [ "$_mt_days" -gt 0 ]; then
				_mt_n="$(find "$_mt_dir" -maxdepth 1 -type f -mtime +"$_mt_days" ! -mmin -10 2>/dev/null | wc -l)"
				if [ "${_mt_n:-0}" -gt 0 ]; then
					_mt_del=$((_mt_del + _mt_n))
					if [ "$_mt_dry" != "1" ]; then
						find "$_mt_dir" -maxdepth 1 -type f -mtime +"$_mt_days" ! -mmin -10 \
							-exec rm -f {} + 2>/dev/null
					fi
				fi
			fi
			# 2) count cap: keep the newest entries, drop the rest
			_mt_tot="$(ls -1 "$_mt_dir" 2>/dev/null | wc -l)"
			[ "${_mt_tot:-0}" -le "$_mt_keep" ] && continue
			_mt_excess=$((_mt_tot - _mt_keep))
			[ "$_mt_tot" -le "$_mt_min" ] && continue
			# oldest first by mtime; numeric order is not reliable across platforms
			_mt_list="$(ls -1t "$_mt_dir" 2>/dev/null | tail -n "$_mt_excess")"
			[ -z "$_mt_list" ] && continue
			_mt_trunc=$((_mt_trunc + _mt_excess))
			if [ "$_mt_dry" != "1" ]; then
				printf '%s\n' "$_mt_list" | while read -r _mt_f; do
					[ -n "$_mt_f" ] && rm -f "$_mt_dir/$_mt_f"
				done
			fi
		done
	done
	if [ "$_mt_del" -gt 0 ] || [ "$_mt_trunc" -gt 0 ]; then
		printf '%s maint: state trim%s aged=%s over_cap=%s keep_days=%s keep_items=%s\n' \
			"$(date +%FT%T)" "$([ "$_mt_dry" = "1" ] && printf ' (dry-run)')" \
			"$_mt_del" "$_mt_trunc" "$_mt_days" "$_mt_keep" >> "$_MAINT_LOG_DIR/bot.log"
	fi
	return 0
}

# maint_report — state/log sizes for the webui (stdout, key=value)
maint_report() {
	_mp_logs="$(du -sk "$_MAINT_LOG_DIR" 2>/dev/null | awk '{print $1}')"
	_mp_state="$(du -sk "$_HB/var/state" 2>/dev/null | awk '{print $1}')"
	_mp_img="$(du -sk "$_MAINT_TMP_IMG" 2>/dev/null | awk '{print $1}')"
	printf 'logs_kb=%s\nstate_kb=%s\nimg_kb=%s\n' "${_mp_logs:-0}" "${_mp_state:-0}" "${_mp_img:-0}"
}

# maint_run [boot|cron]
maint_run() {
	_mr_why="${1:-cron}"
	mkdir -p "$_MAINT_LOG_DIR" 2>/dev/null
	maint_rotate "$_MAINT_LOG_DIR/bot.log" 5242880 2
	maint_rotate "$_MAINT_LOG_DIR/error.log" 5242880 2
	maint_rotate "$_MAINT_LOG_DIR/cron.log" 2097152 2
	# anything else that logs into var/log (adapter debug logs, ad-hoc scripts)
	# used to grow forever: rotate every remaining *.log, same ceiling
	for _mr_lf in "$_MAINT_LOG_DIR"/*.log; do
		[ -f "$_mr_lf" ] || continue
		case "$_mr_lf" in
			*/bot.log|*/error.log|*/cron.log) continue ;;
		esac
		maint_rotate "$_mr_lf" 2097152 2
	done
	maint_clean_tmp 60
	maint_trim_state
	# post-trim size report (state maps shrink, never zeroed)
	_st_kb="$(du -sk "$_HB/var/state" 2>/dev/null | awk '{print $1}')"
	if [ "${_st_kb:-0}" -gt 3145728 ]; then
		printf '%s maint: WARN var/state is %s KB (msg maps kept, manual review advised)\n' \
			"$(date +%FT%T)" "$_st_kb" >> "$_MAINT_LOG_DIR/bot.log"
	fi
	printf '%s maint: %s done state_kb=%s\n' "$(date +%FT%T)" "$_mr_why" "${_st_kb:-0}" >> "$_MAINT_LOG_DIR/bot.log"
	return 0
}

# crontab entry point (cron invokes the function with no arguments)
maint_cron() { maint_run cron; }
