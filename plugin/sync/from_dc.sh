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

# Forward DC attachments to QQ (download -> QQ segment/file upload)
_sync_dc_attachments_to_qq() {
	_raw="$1" _gid="$2" _sender="$3"
	_atts="$(json_get "$_raw" attachments 2>/dev/null)" || _atts=""
	if [ -z "$_atts" ] || [ "$_atts" = "NOTFOUND" ]; then return 0; fi
	# Split attachment array
	_items="$(printf '%s' "$_atts" | sed 's/},{/}\n{/g')"
	_sent=0
	IFS='
'
	for _att in $_items; do
		_url="$(json_get "$_att" url 2>/dev/null)" || _url=""
		_fn="$(json_get "$_att" filename 2>/dev/null)" || _fn="file"
		_ct="$(json_get "$_att" content_type 2>/dev/null)" || _ct=""
		[ "$_url" = "NOTFOUND" ] && continue
		[ -z "$_url" ] && continue
		_fn="$(utf8_decode "$_fn")"
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-dc-qq-$$-$_ts"
		http_get_file "$_url" "$_tmp" || { log_err "sync: dc->qq att download FAIL"; rm -f "$_tmp"; continue; }
		# Image → QQ image segment, others → file upload
		case "$_ct" in
			image/*)
				_furi="file:///root/img/sync-dc-qq-$$-$_ts"
				_img_msg="[{\"type\":\"image\",\"data\":{\"uri\":\"$_furi\",\"summary\":\"👾 $_sender: [图片]\"}}]"
				if qq_message_send_group "$_gid" "$_img_msg" >/dev/null; then
					_sent=$((_sent + 1)); log_info "sync: dc->qq image OK"
				else
					log_err "sync: dc->qq image FAIL: $_ERROR"
				fi
				;;
			*)
				_furi="file:///root/img/sync-dc-qq-$$-$_ts"
				if qq_file_upload_group "$_gid" "$_furi" "$_fn" >/dev/null; then
					_sent=$((_sent + 1)); log_info "sync: dc->qq file OK $_fn"
				else
					log_err "sync: dc->qq file FAIL: $_ERROR"
				fi
				;;
		esac
		rm -f "$_tmp"
	done
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward DC attachments to TG (download -> multipart sendDocument)
_sync_dc_attachments_to_tg() {
	_raw="$1" _tcid="$2" _sender="$3"
	_atts="$(json_get "$_raw" attachments 2>/dev/null)" || _atts=""
	if [ -z "$_atts" ] || [ "$_atts" = "NOTFOUND" ]; then return 0; fi
	_items="$(printf '%s' "$_atts" | sed 's/},{/}\n{/g')"
	_sent=0
	IFS='
'
	for _att in $_items; do
		_url="$(json_get "$_att" url 2>/dev/null)" || _url=""
		_fn="$(json_get "$_att" filename 2>/dev/null)" || _fn="file"
		_ct="$(json_get "$_att" content_type 2>/dev/null)" || _ct=""
		[ "$_url" = "NOTFOUND" ] && continue
		[ -z "$_url" ] && continue
		_fn="$(utf8_decode "$_fn")"
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-dc-tg-$$-$_ts"
		http_get_file "$_url" "$_tmp" || { log_err "sync: dc->tg att download FAIL"; rm -f "$_tmp"; continue; }
		if _sync_tg_multipart "$_tcid" "" "$_tmp" "$_fn" "sendDocument" "document" "$_ct" "👾 $_sender: [文件] $_fn"; then
			_sent=$((_sent + 1)); log_info "sync: dc->tg file OK $_fn"
		else
			log_err "sync: dc->tg file FAIL: $_ERROR"
		fi
		rm -f "$_tmp"
	done
	[ $_sent -gt 0 ] && return 0 || return 1
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
	_atts="$(json_get "$_raw" attachments 2>/dev/null)" || _atts=""
	# Skip if no text and no attachments
	if [ -z "$_txt" ] && [ "$_atts" = "NOTFOUND" ] && [ "$_type" != "0" ]; then return 0; fi

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
			group/*)
				_gid="${_tid#group/}"
				_sync_dc_text_to_qq "$_raw" "$_gid"
				_sync_dc_attachments_to_qq "$_raw" "$_gid"
				;;
			esac
			;;
		telegram)
			_sync_dc_text_to_tg "$_raw" "$_tid"
			_sync_dc_attachments_to_tg "$_raw" "$_tid"
			;;
		esac
	done < "$_conf"
}
