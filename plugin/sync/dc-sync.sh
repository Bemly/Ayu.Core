# plugin/sync/dc-sync.sh — Per-minute Discord message sync to QQ/TG
# Called by crond via etc/crontab entry:
#   */1 * * * *|../plugin/sync/dc-sync.sh|dc_batch_run

dc_batch_run() {
    # ---- bootstrap ----
	[ -z "${_HB:-}" ] && _HB="$(pwd)"
	. "$_HB/lib/core.sh"
	. "$_HB/etc/config.sh"
	. "$_HB/lib/log.sh"
	. "$_HB/lib/http.sh"
	. "$_HB/adapter/discord/core.sh"
	. "$_HB/adapter/discord/message.sh"
	. "$_HB/plugin/sync/common.sh"
	. "$_HB/plugin/sync/from_dc.sh"

	if [ -z "$DC_TOKEN" ]; then
		log_err "dc-sync: DC_TOKEN not configured"
		return 1
	fi

	_conf="${_SYNC_CONF:-$_HB/etc/sync.conf}"
	if [ ! -f "$_conf" ]; then
		log_warn "dc-sync: no sync.conf"
		return 0
	fi

	log_info "dc-sync: starting fetch"

    # Collect unique DC source channels from sync.conf
	_channels=""
	while IFS='=' read -r _src _tgt; do
		case "$_src" in \#*|"") continue ;; esac
		_spf="${_src%%/*}"
		[ "$_spf" != "discord" ] && continue
		_cid="${_src#*/}"
		_channels="$_channels $_cid"
	done < "$_conf"

	_channels="$(printf '%s' "$_channels" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
	log_info "dc-sync: channels=$_channels"

	_total=0 _fwd=0
	_cur_dir="$_STATE_DIR/dc-cursor"

	for _cid in $_channels; do
		[ -z "$_cid" ] && continue
		log_info "dc-sync: fetching channel $_cid"

        # Use cursor file to fetch only new messages (after cursor)
        # First run: limit to last 10 messages (skip backlog)
        # Subsequent runs: fetch all messages after cursor
		_cur_file="$_cur_dir/$_cid"
		_after=""
		_limit="10"
		if [ -f "$_cur_file" ]; then
			_after="$(cat "$_cur_file" 2>/dev/null)"
			_limit="100"
		fi

        # API endpoint: after parameter = get messages newer than cursor
		_ep="/channels/$_cid/messages?limit=$_limit"
		[ -n "$_after" ] && _ep="$_ep&after=$_after"

        # Use temp file to avoid $() subshell (preserves _ERROR chain)
		_tmp="/tmp/dc-sync-list-$$"
		_dc_get "$_ep" > "$_tmp" 2>/dev/null || {
			log_err "dc-sync: list FAIL $_cid: $_ERROR"; rm -f "$_tmp"; continue
		}
		_dcresp="$(cat "$_tmp" 2>/dev/null)"
		rm -f "$_tmp"
		if [ -z "$_dcresp" ] || [ "$_dcresp" = "NOTFOUND" ] || [ "$_dcresp" = "[]" ]; then continue; fi

		# Use hush-json array iteration (not sed split — id is not first field)
		_len="$(json_arr_len "$_dcresp" 2>/dev/null)" || { log_err "dc-sync: json_arr_len FAIL $_cid"; continue; }
		log_info "dc-sync: _len=$_len _after=$_after"
		_newest=""

		_i=$((_len - 1))
		while [ $_i -ge 0 ]; do
			_msg="$(json_arr_at "$_dcresp" "$_i" 2>/dev/null)" || { log_info "dc-sync: arr_at FAIL _i=$_i"; _i=$((_i - 1)); continue; }
			_total=$((_total + 1))
			_mid="$(json_get "$_msg" id 2>/dev/null)" || _mid=""

			# Track newest ID for cursor update (numeric cmp — Discord snowflakes fit in 64-bit)
			if [ -n "$_mid" ] && [ "$_mid" != "NOTFOUND" ]; then
				if [ -z "$_newest" ] || [ "$_mid" -gt "$_newest" ] 2>/dev/null; then
					_newest="$_mid"
				fi
			fi

			# Skip already-processed messages (id <= cursor)
			if [ -n "$_after" ] && [ -n "$_mid" ] && [ "$_mid" != "NOTFOUND" ] && [ "$_mid" -le "$_after" ] 2>/dev/null; then
				[ $_total -le 5 ] && log_info "dc-sync: SKIP _i=$_i _mid=$_mid _after=$_after"
				_i=$((_i - 1)); continue
			fi

			[ $_total -le 5 ] && log_info "dc-sync: FWD _i=$_i _mid=$_mid _after=$_after _newest=$_newest"
			sync_dc_message "$_msg" "$_cid"
			_fwd=$((_fwd + 1))
			_i=$((_i - 1))
		done

        # Update cursor: never go backwards (max of old cursor and newest seen)
		if [ -z "$_newest" ]; then _newest="$_after"; fi
		if [ -n "$_after" ] && [ -n "$_newest" ] && [ "$_newest" -lt "$_after" ] 2>/dev/null; then
			_newest="$_after"
		fi
		if [ -n "$_newest" ]; then
			mkdir -p "$_cur_dir" 2>/dev/null
			mkdir -p "$_HB/var/log" 2>/dev/null
			if printf '%s' "$_newest" > "$_cur_file" 2>/dev/null; then
				log_info "dc-sync: cursor=$_cid=$_newest fwd=$_fwd"
			else
				log_err "dc-sync: cursor write FAIL: $_cid"
			fi
		fi
	done

	log_info "dc-sync: done total=$_total fwd=$_fwd"
	return 0
}
