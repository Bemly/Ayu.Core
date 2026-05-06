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

		# Use cursor file to avoid re-forwarding already-seen messages
		_cur_file="$_cur_dir/$_cid"
		_after=""
		if [ -f "$_cur_file" ]; then
			_after="$(cat "$_cur_file" 2>/dev/null)"
		fi

		# Use temp file to avoid $() subshell (preserves _ERROR chain)
		_tmp="/tmp/dc-sync-list-$$"
		dc_message_list "$_cid" > "$_tmp" 2>/dev/null || {
			log_err "dc-sync: list FAIL $_cid: $_ERROR"; rm -f "$_tmp"; continue
		}
		_resp="$(cat "$_tmp" 2>/dev/null)"
		rm -f "$_tmp"
		if [ -z "$_resp" ] || [ "$_resp" = "NOTFOUND" ] || [ "$_resp" = "[]" ]; then continue; fi

		_msgs="$(printf '%s' "$_resp" | sed 's/^{"id":"/\n{"id":"/g' | sed 's/^\[//;s/\]$//' | grep -v '^$')"
		_newest=""

		for _msg in $_msgs; do
			[ -z "$_msg" ] && continue
			_total=$((_total + 1))
			_mid="$(json_get "$_msg" id 2>/dev/null)" || _mid=""

			# Save newest ID for cursor update
			if [ -n "$_mid" ] && [ "$_mid" != "NOTFOUND" ]; then
				[ -z "$_newest" ] && _newest="$_mid"
			fi

			# Skip already-processed messages
			[ -n "$_after" ] && [ "$_mid" = "$_after" ] && break

			sync_dc_message "$_msg" "$_cid"
			_fwd=$((_fwd + 1))
		done

		# Update cursor
		if [ -n "$_newest" ]; then
			mkdir -p "$_cur_dir" 2>/dev/null
			printf '%s' "$_newest" > "$_cur_file"
		fi
	done

	log_info "dc-sync: done total=$_total fwd=$_fwd"
	return 0
}
