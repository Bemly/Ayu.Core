_sync_tg_photo_to_qq() {
	_raw="$1" _gid="$2"
	_photos="$(json_get "$_raw" photo 2>/dev/null)" || return 1
	if [ -z "$_photos" ] || [ "$_photos" = "NOTFOUND" ]; then return 1; fi
	_fid="$(printf '%s' "$_photos" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p' | tail -1)"
	if [ -z "$_fid" ]; then return 1; fi
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg-qq photo getFile FAIL err=$_ERROR"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then
		log_err "sync: tg→qq no file_path"; return 1
	fi
	_fname="${_path##*/}"
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-img-tg-$$-$_ts.${_fname##*.}"
	_furi="file:///root/img/sync-img-tg-$$-$_ts.${_fname##*.}"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || {
		log_err "sync: tg→qq download FAIL"; rm -f "$_tmp"; return 1
	}
	# Build image segment array → send via send_group_message
	_img_msg="[{\"type\":\"image\",\"data\":{\"uri\":\"$_furi\",\"summary\":\"[图片]\"}}]"
	if qq_message_send_group "$_gid" "$_img_msg" >/dev/null; then
		log_info "sync: tg→qq image OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg→qq image FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG sticker to QQ (download from TG via CF Worker, upload to QQ as image)
_sync_tg_sticker_to_qq() {
	_raw="$1" _gid="$2"
	_sticker="$(json_get "$_raw" sticker 2>/dev/null)" || return 1
	if [ -z "$_sticker" ] || [ "$_sticker" = "NOTFOUND" ]; then return 1; fi
	_fid="$(printf '%s' "$_sticker" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p' | tail -1)"
	if [ -z "$_fid" ]; then return 1; fi
	_ian="$(json_get "$_sticker" is_animated 2>/dev/null)" || _ian=""
	_ivd="$(json_get "$_sticker" is_video 2>/dev/null)" || _ivd=""
	_stp="$(json_get "$_sticker" type 2>/dev/null)" || _stp=""
	log_debug "sync: sticker fid=$_fid animated=$_ian video=$_ivd type=$_stp"
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg-qq sticker getFile FAIL err=$_ERROR"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then
		log_err "sync: tg→qq sticker no file_path"; return 1
	fi
	log_debug "sync: sticker path=$_path"
	_fname="${_path##*/}"
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-sticker-tg-$$-$_ts.${_fname##*.}"
	_furi="file:///root/img/sync-sticker-tg-$$-$_ts.${_fname##*.}"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || {
		log_err "sync: tg→qq sticker download FAIL"; rm -f "$_tmp"; return 1
	}
	_sz=$(wc -c < "$_tmp" 2>/dev/null)
	log_debug "sync: sticker downloaded sz=$_sz tmp=$_tmp"
	# Video/animated → upload as file (WEBM/TGS can't be QQ image) — pic compress error
	if [ "$_ivd" = "true" ] || [ "$_ian" = "true" ]; then
		_fn="sticker.${_fname##*.}"
		if qq_file_upload_group "$_gid" "$_furi" "$_fn" >/dev/null; then
			log_info "sync: tg→qq sticker file OK"; rm -f "$_tmp"; return 0
		else
			log_err "sync: tg→qq sticker file FAIL: $_ERROR"; rm -f "$_tmp"; return 1
		fi
	fi
	_emoji="$(json_get "$_sticker" emoji 2>/dev/null)" || _emoji=""
	_lbl="[贴纸]"
	[ -n "$_emoji" ] && [ "$_emoji" != "NOTFOUND" ] && _lbl="[贴纸: $_emoji]"
	_img_msg="[{\"type\":\"image\",\"data\":{\"uri\":\"$_furi\",\"summary\":\"$_lbl\"}}]"
	if qq_message_send_group "$_gid" "$_img_msg" >/dev/null; then
		log_info "sync: tg→qq sticker OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg→qq sticker FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG animation (GIF) to QQ (download from TG via CF Worker, upload to QQ)
_sync_tg_animation_to_qq() {
	_raw="$1" _gid="$2"
	_ani="$(json_get "$_raw" animation 2>/dev/null)" || return 1
	if [ -z "$_ani" ] || [ "$_ani" = "NOTFOUND" ]; then return 1; fi
	_fid="$(printf '%s' "$_ani" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p' | tail -1)"
	if [ -z "$_fid" ]; then return 1; fi
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg-qq animation getFile FAIL err=$_ERROR"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then
		log_err "sync: tg→qq animation no file_path"; return 1
	fi
	_fname="${_path##*/}"
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-gif-tg-$$-$_ts.${_fname##*.}"
	_furi="file:///root/img/sync-gif-tg-$$-$_ts.${_fname##*.}"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || {
		log_err "sync: tg→qq animation download FAIL"; rm -f "$_tmp"; return 1
	}
		# Upload as file (TG converts GIF to MP4, QQ cannot display MP4 as image)
		if qq_file_upload_group "$_gid" "$_furi" "$_fname" >/dev/null; then
		log_info "sync: tg→qq animation OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg→qq animation FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG document to QQ (download via CF Worker, upload via upload_group_file)
_sync_tg_document_to_qq() {
	_raw="$1" _gid="$2"
	_doc="$(json_get "$_raw" document 2>/dev/null)" || return 1
	if [ -z "$_doc" ] || [ "$_doc" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_doc" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	_fn="$(json_get "$_doc" file_name 2>/dev/null)" || _fn="file"
	_fn="$(utf8_decode "$_fn")"
	_fsz="$(json_get "$_doc" file_size 2>/dev/null)" || _fsz=""
	if [ -n "$_fsz" ] && [ "$_fsz" != "NOTFOUND" ] && [ "$_fsz" -gt 20000000 ] 2>/dev/null; then
		log_info "sync: tg-qq file skip too big ($_fsz bytes)"; return 0
	fi
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg-qq file getFile FAIL err=$_ERROR"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then
		log_err "sync: tg→qq file no file_path"; return 1
	fi
	_ts=$(date +%s)
	_ext="${_fn##*.}"
	[ "$_ext" = "$_fn" ] && _ext=""
	[ -n "$_ext" ] && _ext=".$_ext"
	_tmp="/tmp/img/sync-file-tg-$$-$_ts$_ext"
	_furi="file:///root/img/sync-file-tg-$$-$_ts$_ext"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || {
		log_err "sync: tg→qq file download FAIL"; rm -f "$_tmp"; return 1
	}
	_errf="/tmp/qq-up-err.$$"
	if qq_file_upload_group "$_gid" "$_furi" "$_fn" >"$_errf" 2>"$_errf"; then
		log_info "sync: tg→qq file OK"; rm -f "$_tmp" "$_errf"; return 0
	else
		log_err "sync: tg→qq file FAIL: _ERROR=[$_ERROR] qq_resp=[$(cat $_errf 2>/dev/null)]"; rm -f "$_tmp" "$_errf"; return 1
	fi
}

# Main sync handler — called by dispatch

# Forward TG voice to QQ (download via CF Worker, upload as QQ record segment)
_sync_tg_voice_to_qq() {
	_raw="$1" _gid="$2"
	_voice="$(json_get "$_raw" voice 2>/dev/null)" || return 1
	if [ -z "$_voice" ] || [ "$_voice" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_voice" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg-qq voice getFile FAIL err=$_ERROR"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then
		log_err "sync: tg-qq voice no file_path"; return 1
	fi
	_fname="${_path##*/}"
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-voice-tg-$$-$_ts.${_fname##*.}"
	_furi="file:///root/img/sync-voice-tg-$$-$_ts.${_fname##*.}"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || {
		log_err "sync: tg-qq voice download FAIL"; rm -f "$_tmp"; return 1
	}
	_rec_msg="[{\"type\":\"record\",\"data\":{\"uri\":\"$_furi\"}}]"
	if qq_message_send_group "$_gid" "$_rec_msg" >/dev/null; then
		log_info "sync: tg-qq voice OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg-qq voice FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG audio to QQ (download via CF Worker, upload as QQ file)
_sync_tg_audio_to_qq() {
	_raw="$1" _gid="$2"
	_audio="$(json_get "$_raw" audio 2>/dev/null)" || return 1
	if [ -z "$_audio" ] || [ "$_audio" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_audio" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	_title="$(json_get "$_audio" title 2>/dev/null)" || _title=""
	[ "$_title" = "NOTFOUND" ] && _title=""
	_fsz="$(json_get "$_audio" file_size 2>/dev/null)" || _fsz=""
	if [ -n "$_fsz" ] && [ "$_fsz" != "NOTFOUND" ] && [ "$_fsz" -gt 20000000 ] 2>/dev/null; then
		log_info "sync: tg-qq audio skip too big ($_fsz bytes)"; return 0
	fi
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg-qq audio getFile FAIL err=$_ERROR"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then
		log_err "sync: tg-qq audio no file_path"; return 1
	fi
	_fname="${_path##*/}"
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-audio-tg-$$-$_ts.${_fname##*.}"
	_furi="file:///root/img/sync-audio-tg-$$-$_ts.${_fname##*.}"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || {
		log_err "sync: tg-qq audio download FAIL"; rm -f "$_tmp"; return 1
	}
	_fn="audio"
	[ -n "$_title" ] && _fn="${_title}.${_fname##*.}"
	if qq_file_upload_group "$_gid" "$_furi" "$_fn" >/dev/null; then
		log_info "sync: tg-qq audio OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg-qq audio FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG video to QQ (download via CF Worker, upload as QQ video segment)
_sync_tg_video_to_qq() {
	_raw="$1" _gid="$2"
	_video="$(json_get "$_raw" video 2>/dev/null)" || return 1
	if [ -z "$_video" ] || [ "$_video" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_video" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	_fsz="$(json_get "$_video" file_size 2>/dev/null)" || _fsz=""
	if [ -n "$_fsz" ] && [ "$_fsz" != "NOTFOUND" ] && [ "$_fsz" -gt 20000000 ] 2>/dev/null; then
		log_info "sync: tg-qq video skip too big ($_fsz bytes)"; return 0
	fi
	_fpfile="/tmp/tg-vid-fp-$$"
	tg_getFile "$_fid" > "$_fpfile" 2>/dev/null || { log_err "sync: tg-qq video getFile FAIL fid=$_fid err=$_ERROR"; rm -f "$_fpfile"; return 1; }
	_fp="$(cat "$_fpfile")"; rm -f "$_fpfile"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then
		log_err "sync: tg-qq video no file_path"; return 1
	fi
	_fname="${_path##*/}"
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-video-tg-$$-$_ts.${_fname##*.}"
	_furi="file:///root/img/sync-video-tg-$$-$_ts.${_fname##*.}"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || {
		log_err "sync: tg-qq video download FAIL"; rm -f "$_tmp"; return 1
	}
	_vid_msg="[{\"type\":\"video\",\"data\":{\"uri\":\"$_furi\"}}]"
	if qq_message_send_group "$_gid" "$_vid_msg" >/dev/null; then
		log_info "sync: tg-qq video OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg-qq video FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG photo to DC (tg_getFile -> download -> upload via multipart)
_sync_tg_photo_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_photos="$(json_get "$_raw" photo 2>/dev/null)" || return 1
	if [ -z "$_photos" ] || [ "$_photos" = "NOTFOUND" ]; then return 1; fi
	_fid="$(printf '%s' "$_photos" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p' | tail -1)"
	if [ -z "$_fid" ]; then return 1; fi
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg->dc photo getFile FAIL"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then log_err "sync: tg->dc photo no file_path"; return 1; fi
	_fname="${_path##*/}"
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-dc-tg-img-$$-$_ts"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || { log_err "sync: tg->dc photo download FAIL"; rm -f "$_tmp"; return 1; }
	if _sync_dc_multipart "$_cid" "$_tmp" "$_fname" "image/jpeg" "✈️ $_sender: [图片]"; then
		log_info "sync: tg->dc photo OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg->dc photo FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG document to DC (download, multipart POST)
_sync_tg_document_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_doc="$(json_get "$_raw" document 2>/dev/null)" || return 1
	if [ -z "$_doc" ] || [ "$_doc" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_doc" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	_fn="$(json_get "$_doc" file_name 2>/dev/null)" || _fn="file"
	[ "$_fn" = "NOTFOUND" ] && _fn="file"
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg->dc doc getFile FAIL"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then log_err "sync: tg->dc doc no file_path"; return 1; fi
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-dc-tg-doc-$$-$_ts"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || { log_err "sync: tg->dc doc download FAIL"; rm -f "$_tmp"; return 1; }
	if _sync_dc_multipart "$_cid" "$_tmp" "$_fn" "application/octet-stream" "✈️ $_sender: [文件] $_fn"; then
		log_info "sync: tg->dc doc OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg->dc doc FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG voice to DC (download, multipart POST)
_sync_tg_voice_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_voice="$(json_get "$_raw" voice 2>/dev/null)" || return 1
	if [ -z "$_voice" ] || [ "$_voice" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_voice" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg->dc voice getFile FAIL"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then log_err "sync: tg->dc voice no file_path"; return 1; fi
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-dc-tg-voice-$$-$_ts"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || { log_err "sync: tg->dc voice download FAIL"; rm -f "$_tmp"; return 1; }
	if _sync_dc_multipart "$_cid" "$_tmp" "voice.ogg" "audio/ogg" "✈️ $_sender: [语音]"; then
		log_info "sync: tg->dc voice OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg->dc voice FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG video to DC (download, multipart POST)
_sync_tg_video_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_video="$(json_get "$_raw" video 2>/dev/null)" || return 1
	if [ -z "$_video" ] || [ "$_video" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_video" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg->dc video getFile FAIL"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then log_err "sync: tg->dc video no file_path"; return 1; fi
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-dc-tg-video-$$-$_ts"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || { log_err "sync: tg->dc video download FAIL"; rm -f "$_tmp"; return 1; }
	if _sync_dc_multipart "$_cid" "$_tmp" "video.mp4" "video/mp4" "✈️ $_sender: [视频]"; then
		log_info "sync: tg->dc video OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg->dc video FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG sticker to DC (static->image, video->file)
_sync_tg_sticker_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_sticker="$(json_get "$_raw" sticker 2>/dev/null)" || return 1
	if [ -z "$_sticker" ] || [ "$_sticker" = "NOTFOUND" ]; then return 1; fi
	_fid="$(printf '%s' "$_sticker" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p' | tail -1)"
	if [ -z "$_fid" ]; then return 1; fi
	_ani="$(json_get "$_sticker" is_animated 2>/dev/null)" || _ani=""
	_vid="$(json_get "$_sticker" is_video 2>/dev/null)" || _vid=""
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg->dc sticker getFile FAIL"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then log_err "sync: tg->dc sticker no file_path"; return 1; fi
	_ts=$(date +%s)
	_ext="${_path##*.}"
	_tmp="/tmp/img/sync-dc-tg-sticker-$$-$_ts.$_ext"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || { log_err "sync: tg->dc sticker download FAIL"; rm -f "$_tmp"; return 1; }
	if [ "$_vid" = "true" ] || [ "$_ani" = "true" ]; then
		_cap="✈️ $_sender: [贴纸-视频]"
		_mime="video/webm"
	else
		_cap="✈️ $_sender: [贴纸]"
		_mime="image/webp"
	fi
	if _sync_dc_multipart "$_cid" "$_tmp" "sticker.$_ext" "$_mime" "$_cap"; then
		log_info "sync: tg->dc sticker OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg->dc sticker FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}

# Forward TG animation (GIF -> DC file)
_sync_tg_animation_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_ani="$(json_get "$_raw" animation 2>/dev/null)" || return 1
	if [ -z "$_ani" ] || [ "$_ani" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_ani" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || { log_err "sync: tg->dc anim getFile FAIL"; return 1; }
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then log_err "sync: tg->dc anim no file_path"; return 1; fi
	_ts=$(date +%s)
	_tmp="/tmp/img/sync-dc-tg-anim-$$-$_ts"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tmp" "X-Ayu-Token: ${TG_API_SECRET}" || { log_err "sync: tg->dc anim download FAIL"; rm -f "$_tmp"; return 1; }
	if _sync_dc_multipart "$_cid" "$_tmp" "animation.mp4" "video/mp4" "✈️ $_sender: [GIF]"; then
		log_info "sync: tg->dc anim OK"; rm -f "$_tmp"; return 0
	else
		log_err "sync: tg->dc anim FAIL: $_ERROR"; rm -f "$_tmp"; return 1
	fi
}
