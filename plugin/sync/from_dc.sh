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
	_resp_file="/tmp/dc-qq-resp-$$"
	if qq_message_send_group "$_gid" "$_segs" > "$_resp_file" 2>/dev/null; then
		_resp="$(cat "$_resp_file" 2>/dev/null)"; rm -f "$_resp_file"
		_seq="$(json_get "$_resp" message_seq 2>/dev/null)" || _seq=""
		_mid="$(json_get "$_raw" id 2>/dev/null)" || _mid=""
		_cid="$(json_get "$_raw" channel_id 2>/dev/null)" || _cid=""
		if [ -n "$_seq" ] && [ -n "$_mid" ] && [ "$_seq" != "NOTFOUND" ] && [ "$_mid" != "NOTFOUND" ]; then
			mkdir -p "$_STATE_DIR/msg-map/$_gid" && chmod 777 "$_STATE_DIR/msg-map/$_gid" 2>/dev/null
			printf '%s %s' "$_mid" "$_cid" > "$_STATE_DIR/msg-map/$_gid/$_seq"
			chmod 666 "$_STATE_DIR/msg-map/$_gid/$_seq" 2>/dev/null
			mkdir -p "$_STATE_DIR/msg-map-rev/discord" && chmod 777 "$_STATE_DIR/msg-map-rev/discord" 2>/dev/null
			printf '%s qq/group/%s %s\n' "$_mid" "$_gid" "$_seq" >> "$_STATE_DIR/msg-map-rev/discord/$_mid"
			chmod 666 "$_STATE_DIR/msg-map-rev/discord/$_mid" 2>/dev/null
		fi
		log_info "sync: dc->qq OK seq=$_seq"
	else
		rm -f "$_resp_file"
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
	_txt="$(utf8_decode "$_txt")"
	_text="👾 $_sender: $_txt"
	_chat="${_tcid%%/*}"
	_thr="${_tcid#*/}"
	[ "$_thr" = "$_chat" ] && _thr=""
	if [ -n "$_thr" ]; then
		_body="$(json_obj "chat_id" "$_chat" "text" "$_text" "message_thread_id" "$_thr")"
	else
		_body="$(json_obj "chat_id" "$_chat" "text" "$_text")"
	fi
	_resp_file="/tmp/dc-tg-resp-$$"
	if _tg_api "sendMessage" "$_body" "sync.dc" > "$_resp_file" 2>/dev/null; then
		_resp="$(cat "$_resp_file" 2>/dev/null)"; rm -f "$_resp_file"
		_tmid="$(json_get "$_resp" message_id 2>/dev/null)" || _tmid=""
		_mid="$(json_get "$_raw" id 2>/dev/null)" || _mid=""
		if [ -n "$_tmid" ] && [ -n "$_mid" ] && [ "$_tmid" != "NOTFOUND" ] && [ "$_mid" != "NOTFOUND" ]; then
			mkdir -p "$_STATE_DIR/msg-map/$_chat" && chmod 777 "$_STATE_DIR/msg-map/$_chat" 2>/dev/null
			printf '%s' "$_mid" > "$_STATE_DIR/msg-map/$_chat/$_tmid"
			chmod 666 "$_STATE_DIR/msg-map/$_chat/$_tmid" 2>/dev/null
			mkdir -p "$_STATE_DIR/msg-map-rev/discord" && chmod 777 "$_STATE_DIR/msg-map-rev/discord" 2>/dev/null
			printf '%s telegram/%s/%s %s\n' "$_mid" "$_chat" "${_tmid}" "$_tmid" >> "$_STATE_DIR/msg-map-rev/discord/$_mid"
			chmod 666 "$_STATE_DIR/msg-map-rev/discord/$_mid" 2>/dev/null
		fi
		log_info "sync: dc->tg OK msgid=$_tmid"
	else
		rm -f "$_resp_file"
		log_err "sync: dc->tg FAIL: $_ERROR"
	fi
}

# Forward DC attachments to QQ (download -> QQ segment/file upload)
_sync_dc_attachments_to_qq() {
	_raw="$1" _gid="$2" _sender="$3"
	_atts="$(json_get "$_raw" attachments 2>/dev/null)" || _atts=""
	if [ -z "$_atts" ] || [ "$_atts" = "NOTFOUND" ]; then
		log_debug "sync: dc->qq no atts, raw[200]=$(printf '%.200s' "$_raw")"
		return 0
	fi
	# Split attachment array
	_items="$(printf '%s' "$_atts" | sed 's/},{/}\n{/g')"
	_sent=0
	log_debug "sync: dc->qq atts=$(printf '%.200s' "$_atts")"
	IFS='
'
	for _att in $_items; do
		log_debug "sync: dc->qq att_url_ct: url=[$(json_get "$_att" url 2>/dev/null)] ct=[$(json_get "$_att" content_type 2>/dev/null)]"
		_url="$(json_get "$_att" url 2>/dev/null)" || _url=""
		_fn="$(json_get "$_att" filename 2>/dev/null)" || _fn="file"
		_ct="$(json_get "$_att" content_type 2>/dev/null)" || _ct=""
		[ "$_url" = "NOTFOUND" ] && continue
		[ -z "$_url" ] && continue
		_fn="$(utf8_decode "$_fn")"
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-dc-qq-$$-$_ts"
		if [ -n "${DC_CDN_PROXY:-}" ]; then
			_url="$(printf '%s' "$_url" | sed 's|https://cdn\.discordapp\.com/|https://'"${DC_CDN_PROXY}"'/|')"
			http_get_file "$_url" "$_tmp" "${_DC_AYU_AUTH:-}" || { log_err "sync: dc->qq att download FAIL"; rm -f "$_tmp"; continue; }
		else
			http_get_file "$_url" "$_tmp" || { log_err "sync: dc->qq att download FAIL"; rm -f "$_tmp"; continue; }
		fi
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
	if [ -z "$_atts" ] || [ "$_atts" = "NOTFOUND" ]; then
		log_debug "sync: dc->tg no atts, raw[200]=$(printf '%.200s' "$_raw")"
		return 0
	fi
	_chat="${_tcid%%/*}"
	_thr="${_tcid#*/}"
	[ "$_thr" = "$_chat" ] && _thr=""
	_items="$(printf '%s' "$_atts" | sed 's/},{/}\n{/g')"
	_sent=0
	log_debug "sync: dc->tg atts=$(printf '%.200s' "$_atts")"
	IFS='
'
	for _att in $_items; do
		log_debug "sync: dc->tg att_url_ct: url=[$(json_get "$_att" url 2>/dev/null)] ct=[$(json_get "$_att" content_type 2>/dev/null)]"
		_url="$(json_get "$_att" url 2>/dev/null)" || _url=""
		_fn="$(json_get "$_att" filename 2>/dev/null)" || _fn="file"
		_ct="$(json_get "$_att" content_type 2>/dev/null)" || _ct=""
		[ "$_url" = "NOTFOUND" ] && continue
		[ -z "$_url" ] && continue
		_fn="$(utf8_decode "$_fn")"
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-dc-tg-$$-$_ts"
		if [ -n "${DC_CDN_PROXY:-}" ]; then
				_url="$(printf '%s' "$_url" | sed 's|https://cdn\.discordapp\.com/|https://'"${DC_CDN_PROXY}"'/|')"
				http_get_file "$_url" "$_tmp" "${_DC_AYU_AUTH:-}" || { log_err "sync: dc->tg att download FAIL"; rm -f "$_tmp"; continue; }
			else
				http_get_file "$_url" "$_tmp" || { log_err "sync: dc->tg att download FAIL"; rm -f "$_tmp"; continue; }
			fi
			if _sync_tg_multipart "$_chat" "$_thr" "$_tmp" "$_fn" "sendDocument" "document" "$_ct" "👾 $_sender: [文件] $_fn"; then
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
	log_info "sync: dc_msg enter cid=$_cid"
	log_debug "sync: dc_msg raw[300]=$(printf '%.300s' "$_raw")"
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
	# Decode Unicode escapes before loop prevention check
	_txt="$(utf8_decode "$_txt")"
	# Loop prevention: skip messages forwarded from Ayu (emoji prefix)
	case "$_txt" in "👾"*|"🐧"*|"✈️"*) return 0 ;; esac
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
