# plugin/sync/dc-sync.sh — Daily Discord message sync to QQ/TG
# Called by crond via etc/crontab entry:
#   0 0 * * *|../plugin/sync/dc-sync.sh|dc_batch_run

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

	log_info "dc-sync: starting daily fetch"

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

	_today="$(env TZ=UTC date +%Y-%m-%d)"
	_total=0 _fwd=0

	for _cid in $_channels; do
		[ -z "$_cid" ] && continue
		log_info "dc-sync: fetching channel $_cid"

		# Use temp file to avoid $() subshell (preserves _ERROR chain)
		_tmp="/tmp/dc-sync-list-$$"
		dc_message_list "$_cid" > "$_tmp" 2>/dev/null || {
			log_err "dc-sync: list FAIL $_cid: $_ERROR"; rm -f "$_tmp"; continue
		}
		_resp="$(cat "$_tmp" 2>/dev/null)"
		rm -f "$_tmp"
		if [ -z "$_resp" ] || [ "$_resp" = "NOTFOUND" ] || [ "$_resp" = "[]" ]; then
			log_info "dc-sync: channel $_cid empty"; continue
		fi

		_msgs="$(printf '%s' "$_resp" | sed 's/^{"id":"/\n{"id":"/g' | sed 's/^\[//;s/\]$//' | grep -v '^$')"

		for _msg in $_msgs; do
			[ -z "$_msg" ] && continue
			_total=$((_total + 1))

			_ts="$(json_get "$_msg" timestamp 2>/dev/null)" || _ts=""
			if [ -z "$_ts" ] || [ "$_ts" = "NOTFOUND" ]; then continue; fi
			case "$_ts" in
				"$_today"*) ;;
				*) continue ;;
			esac

			sync_dc_message "$_msg" "$_cid"
			_fwd=$((_fwd + 1))
		done
	done

	log_info "dc-sync: done total=$_total fwd=$_fwd"
	return 0
}
