_sync_tg_photo_to_qq() {
	_raw="$1" _gid="$2"
	_photos="$(json_get "$_raw" photo 2>/dev/null)" || return 1
	if [ -z "$_photos" ] || [ "$_photos" = "NOTFOUND" ]; then return 1; fi
	_fid="$(printf '%s' "$_photos" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p' | tail -1)"
	[ -z "$_fid" ] && return 1
	_tg_download_file "$_fid" "img" "tg-qq photo" || { log_err "sync: $_ERROR"; return 1; }
	_img_msg="[{\"type\":\"image\",\"data\":{\"uri\":\"$_tg_df_furi\",\"summary\":\"[图片]\"}}]"
	if qq_message_send_group "$_gid" "$_img_msg" >/dev/null; then
		log_info "sync: tg->qq image OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg->qq image FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
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
	_tg_download_file "$_fid" "sticker" "tg-qq sticker" || { log_err "sync: $_ERROR"; return 1; }
	_fname="$_tg_df_name"
	_furi="$_tg_df_furi"
	_tmp="$_tg_df_path"
	log_debug "sync: sticker downloaded sz=$(wc -c < "$_tmp" 2>/dev/null) tmp=$_tmp"
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
	[ -z "$_fid" ] && return 1
	_tg_download_file "$_fid" "gif" "tg-qq animation" || { log_err "sync: $_ERROR"; return 1; }
	if qq_file_upload_group "$_gid" "$_tg_df_furi" "$_tg_df_name" >/dev/null; then
		log_info "sync: tg->qq animation OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg->qq animation FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
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
	if [ -n "$_fsz" ] && [ "$_fsz" != "NOTFOUND" ] && [ "$_fsz" -gt $_SYNC_MAX_FILE_SIZE ] 2>/dev/null; then
		log_info "sync: tg-qq file skip too big ($_fsz bytes)"; return 0
	fi
	_tg_download_file "$_fid" "file" "tg-qq file" || { log_err "sync: $_ERROR"; return 1; }
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
	_tg_download_file "$_fid" "voice" "tg-qq voice" || { log_err "sync: $_ERROR"; return 1; }
	_rec_msg="[{\"type\":\"record\",\"data\":{\"uri\":\"$_tg_df_furi\"}}]"
	if qq_message_send_group "$_gid" "$_rec_msg" >/dev/null; then
		log_info "sync: tg-qq voice OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg-qq voice FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
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
	if [ -n "$_fsz" ] && [ "$_fsz" != "NOTFOUND" ] && [ "$_fsz" -gt $_SYNC_MAX_FILE_SIZE ] 2>/dev/null; then
		log_info "sync: tg-qq audio skip too big ($_fsz bytes)"; return 0
	fi
	_tg_download_file "$_fid" "audio" "tg-qq audio" || { log_err "sync: $_ERROR"; return 1; }
	_fn="audio"
	[ -n "$_title" ] && _fn="${_title}.${_tg_df_name##*.}"
	if qq_file_upload_group "$_gid" "$_tg_df_furi" "$_fn" >/dev/null; then
		log_info "sync: tg-qq audio OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg-qq audio FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
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
	if [ -n "$_fsz" ] && [ "$_fsz" != "NOTFOUND" ] && [ "$_fsz" -gt $_SYNC_MAX_FILE_SIZE ] 2>/dev/null; then
		log_info "sync: tg-qq video skip too big ($_fsz bytes)"; return 0
	fi
	_tg_download_file "$_fid" "video" "tg-qq video" || { log_err "sync: $_ERROR"; return 1; }
	_vid_msg="[{\"type\":\"video\",\"data\":{\"uri\":\"$_tg_df_furi\"}}]"
	if qq_message_send_group "$_gid" "$_vid_msg" >/dev/null; then
		log_info "sync: tg-qq video OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg-qq video FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
	fi
}

# Forward TG photo to DC (tg_getFile -> download -> upload via multipart)
_sync_tg_photo_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_photos="$(json_get "$_raw" photo 2>/dev/null)" || return 1
	if [ -z "$_photos" ] || [ "$_photos" = "NOTFOUND" ]; then return 1; fi
	_fid="$(printf '%s' "$_photos" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p' | tail -1)"
	if [ -z "$_fid" ]; then return 1; fi
	_tg_download_file "$_fid" "dc-tg-img" "tg->dc photo" || { log_err "sync: $_ERROR"; return 1; }
	if _sync_dc_multipart "$_cid" "$_tg_df_path" "$_tg_df_name" "image/jpeg" "✈️ $_sender: [图片]"; then
		log_info "sync: tg->dc photo OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg->dc photo FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
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
	_tg_download_file "$_fid" "dc-tg-doc" "tg->dc doc" || { log_err "sync: $_ERROR"; return 1; }
	if _sync_dc_multipart "$_cid" "$_tg_df_path" "$_fn" "application/octet-stream" "✈️ $_sender: [文件] $_fn"; then
		log_info "sync: tg->dc doc OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg->dc doc FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
	fi
}

# Forward TG voice to DC (download, multipart POST)
_sync_tg_voice_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_voice="$(json_get "$_raw" voice 2>/dev/null)" || return 1
	if [ -z "$_voice" ] || [ "$_voice" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_voice" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	_tg_download_file "$_fid" "dc-tg-voice" "tg->dc voice" || { log_err "sync: $_ERROR"; return 1; }
	if _sync_dc_multipart "$_cid" "$_tg_df_path" "voice.ogg" "audio/ogg" "✈️ $_sender: [语音]"; then
		log_info "sync: tg->dc voice OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg->dc voice FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
	fi
}

# Forward TG video to DC (download, multipart POST)
_sync_tg_video_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_video="$(json_get "$_raw" video 2>/dev/null)" || return 1
	if [ -z "$_video" ] || [ "$_video" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_video" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	_tg_download_file "$_fid" "dc-tg-video" "tg->dc video" || { log_err "sync: $_ERROR"; return 1; }
	if _sync_dc_multipart "$_cid" "$_tg_df_path" "video.mp4" "video/mp4" "✈️ $_sender: [视频]"; then
		log_info "sync: tg->dc video OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg->dc video FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
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
	_tg_download_file "$_fid" "dc-tg-sticker" "tg->dc sticker" || { log_err "sync: $_ERROR"; return 1; }
	_ext="${_tg_df_name##*.}"
	if [ "$_vid" = "true" ] || [ "$_ani" = "true" ]; then
		_cap="✈️ $_sender: [贴纸-视频]"
		_mime="video/webm"
	else
		_cap="✈️ $_sender: [贴纸]"
		_mime="image/webp"
	fi
	if _sync_dc_multipart "$_cid" "$_tg_df_path" "sticker.$_ext" "$_mime" "$_cap"; then
		log_info "sync: tg->dc sticker OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg->dc sticker FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
	fi
}

# Forward TG animation (GIF -> DC file)
_sync_tg_animation_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_ani="$(json_get "$_raw" animation 2>/dev/null)" || return 1
	if [ -z "$_ani" ] || [ "$_ani" = "NOTFOUND" ]; then return 1; fi
	_fid="$(json_get "$_ani" file_id 2>/dev/null)" || _fid=""
	if [ -z "$_fid" ] || [ "$_fid" = "NOTFOUND" ]; then return 1; fi
	_tg_download_file "$_fid" "dc-tg-anim" "tg->dc anim" || { log_err "sync: $_ERROR"; return 1; }
	if _sync_dc_multipart "$_cid" "$_tg_df_path" "animation.mp4" "video/mp4" "✈️ $_sender: [GIF]"; then
		log_info "sync: tg->dc anim OK"; rm -f "$_tg_df_path"; return 0
	else
		log_err "sync: tg->dc anim FAIL: $_ERROR"; rm -f "$_tg_df_path"; return 1
	fi
}
