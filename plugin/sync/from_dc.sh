# plugin/sync/from_dc.sh — DC source forwarders (DC -> QQ/TG)

# Forward DC text to QQ
_sync_dc_text_to_qq() {
	_raw="$1" _gid="$2"
	_txt="$(json_get "$_raw" content 2>/dev/null)" || _txt=""
	if [ -z "$_txt" ] || [ "$_txt" = "NOTFOUND" ]; then return 0; fi
	_sender="$(_sync_get_sender "discord" "$_raw")"
	_sender="$(utf8_decode "$_sender")"
	_text="👾 $_sender: $_txt"
	_segs="$(qq_text_segments "$_text")"
	if qq_message_send_group "$_gid" "$_segs" >/dev/null; then
		log_info "sync: dc->qq OK"
	else
		log_err "sync: dc->qq FAIL: $_ERROR"
	fi
}

# Forward DC text to TG
_sync_dc_text_to_tg() {
	_raw="$1" _tcid="$2"
	_txt="$(json_get "$_raw" content 2>/dev/null)" || _txt=""
	if [ -z "$_txt" ] || [ "$_txt" = "NOTFOUND" ]; then return 0; fi
	_sender="$(_sync_get_sender "discord" "$_raw")"
	_sender="$(utf8_decode "$_sender")"
	_text="👾 $_sender: $_txt"
	_body="$(json_obj "chat_id" "$_tcid" "text" "$_text")"
	_tg_api "sendMessage" "$_body" "sync.dc" >/dev/null 2>/dev/null || log_err "sync: dc->tg FAIL: $_ERROR"
}

# Forward one DC message to its QQ/TG targets per sync.conf
# Called from dc-sync.sh batch script
sync_dc_message() {
	_raw="$1" _cid="$2"
	# Skip empty messages and bot's own messages
	_author="$(json_get "$_raw" author 2>/dev/null)" || _author=""
	_aid=""
	if [ -n "$_author" ] && [ "$_author" != "NOTFOUND" ]; then
		_aid="$(json_get "$_author" id 2>/dev/null)" || _aid=""
	fi
	# Skip bot's own messages
	if [ -n "$DC_BOT_ID" ] && [ "$_aid" = "$DC_BOT_ID" ]; then
		return 0
	fi
	# Skip empty content and system messages
	_txt="$(json_get "$_raw" content 2>/dev/null)" || _txt=""
	_type="$(json_get "$_raw" type 2>/dev/null)" || _type=""
	[ "$_txt" = "NOTFOUND" ] && _txt=""
	if [ -z "$_txt" ] && [ "$_type" != "0" ]; then return 0; fi

	_conf="${_SYNC_CONF:-$_HB/etc/sync.conf}"
	[ ! -f "$_conf" ] && return 0

	while IFS='=' read -r _src _tgt; do
		case "$_src" in \#*|"") continue ;; esac
		_spf="${_src%%/*}"
		_sid="${_src#*/}"
		[ "$_spf" != "discord" ] && continue
		[ "$_sid" != "$_cid" ] && continue

		_tpf="${_tgt%%/*}"
		_tid="${_tgt#*/}"

		case "$_tpf" in
		qq)
			case "$_tid" in
			group/*) _sync_dc_text_to_qq "$_raw" "${_tid#group/}" ;;
			esac
			;;
		telegram)
			_sync_dc_text_to_tg "$_raw" "$_tid"
			;;
		esac
	done < "$_conf"
}
