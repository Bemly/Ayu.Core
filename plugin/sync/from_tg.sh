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

# _sync_tg_media_to_qqbot <raw> <token> <sender>
# Forward TG media to the QQ official bot (group/* or private/*).
#
# The bot API accepts binary media either as base64 `file_data` (capped by
# QQBOT_FILE_DATA_MAX, 5 MB) or as a public URL. The TG download URL embeds our
# bot token and only answers with the CF worker's X-Ayu-Token header, so it can
# never be handed to QQ as a public URL. Single path: download → base64 upload.
# Items above the cap are logged and skipped — no silent downgrade to a file.
#
# file_type mapping (see adapter/qqbot/message.sh): 1 image, 2 video, 3 voice,
# 4 file. Static stickers are inline images; video stickers (.webm) and lottie
# (.tgs) cannot be rendered inline by the platform, so they keep their own kind
# (video / file) instead of being pushed through the image path.
_sync_tg_media_to_qqbot() {
	_ftq_raw="$1" _ftq_tid="$2" _ftq_sender="$3"
	case "$_ftq_tid" in
		channel/*) log_debug "sync: tg→qqbot channel media unsupported, skipped"; return 1 ;;
	esac
	_ftq_kind="" _ftq_fid="" _ftq_ty="" _ftq_fn="" _ftq_lbl=""

	_ftq_st="$(json_get "$_ftq_raw" sticker 2>/dev/null)" || _ftq_st=""
	case "$_ftq_st" in
	''|NOTFOUND) ;;
	*)
		_ftq_fid="$(json_get "$_ftq_st" file_id 2>/dev/null)" || _ftq_fid=""
		_ftq_kind="sticker" _ftq_lbl="贴纸"
		if [ "$(json_get "$_ftq_st" is_video 2>/dev/null)" = "true" ]; then
			_ftq_ty=2 _ftq_fn="sticker.webm"
		elif [ "$(json_get "$_ftq_st" is_animated 2>/dev/null)" = "true" ]; then
			_ftq_ty=4 _ftq_fn="sticker.tgs"
		else
			_ftq_ty=1 _ftq_fn="sticker.webp"
		fi
		;;
	esac

	if [ -z "$_ftq_kind" ]; then
		_ftq_ph="$(json_get "$_ftq_raw" photo 2>/dev/null)" || _ftq_ph=""
		case "$_ftq_ph" in
		''|NOTFOUND) ;;
		*)
			# photo is an array of sizes; the last entry is the largest one
			_ftq_fid="$(printf '%s' "$_ftq_ph" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p' | tail -1)"
			_ftq_kind="photo" _ftq_ty=1 _ftq_fn="photo.jpg" _ftq_lbl="图片"
			;;
		esac
	fi

	if [ -z "$_ftq_kind" ]; then
		_ftq_an="$(json_get "$_ftq_raw" animation 2>/dev/null)" || _ftq_an=""
		case "$_ftq_an" in
		''|NOTFOUND) ;;
		*)
			_ftq_fid="$(json_get "$_ftq_an" file_id 2>/dev/null)" || _ftq_fid=""
			_ftq_kind="animation" _ftq_lbl="GIF"
			if [ "$(json_get "$_ftq_an" mime_type 2>/dev/null)" = "image/gif" ]; then
				_ftq_ty=1 _ftq_fn="animation.gif"
			else
				_ftq_ty=2 _ftq_fn="animation.mp4"
			fi
			;;
		esac
	fi

	if [ -z "$_ftq_kind" ]; then
		_ftq_vd="$(json_get "$_ftq_raw" video 2>/dev/null)" || _ftq_vd=""
		case "$_ftq_vd" in
		''|NOTFOUND) ;;
		*)
			_ftq_fid="$(json_get "$_ftq_vd" file_id 2>/dev/null)" || _ftq_fid=""
			_ftq_kind="video" _ftq_ty=2 _ftq_fn="video.mp4" _ftq_lbl="视频"
			;;
		esac
	fi

	if [ -z "$_ftq_kind" ]; then
		_ftq_vc="$(json_get "$_ftq_raw" voice 2>/dev/null)" || _ftq_vc=""
		case "$_ftq_vc" in
		''|NOTFOUND) ;;
		*)
			_ftq_fid="$(json_get "$_ftq_vc" file_id 2>/dev/null)" || _ftq_fid=""
			_ftq_kind="voice" _ftq_ty=3 _ftq_fn="voice.ogg" _ftq_lbl="语音"
			;;
		esac
	fi

	if [ -z "$_ftq_kind" ]; then
		_ftq_au="$(json_get "$_ftq_raw" audio 2>/dev/null)" || _ftq_au=""
		case "$_ftq_au" in
		''|NOTFOUND) ;;
		*)
			_ftq_fid="$(json_get "$_ftq_au" file_id 2>/dev/null)" || _ftq_fid=""
			_ftq_fn="$(json_get "$_ftq_au" file_name 2>/dev/null)" || _ftq_fn=""
			case "$_ftq_fn" in ''|NOTFOUND|null) _ftq_fn="audio.mp3" ;; esac
			_ftq_kind="audio" _ftq_ty=3 _ftq_lbl="音频"
			;;
		esac
	fi

	if [ -z "$_ftq_kind" ]; then
		_ftq_dc="$(json_get "$_ftq_raw" document 2>/dev/null)" || _ftq_dc=""
		case "$_ftq_dc" in
		''|NOTFOUND) ;;
		*)
			_ftq_fid="$(json_get "$_ftq_dc" file_id 2>/dev/null)" || _ftq_fid=""
			_ftq_fn="$(json_get "$_ftq_dc" file_name 2>/dev/null)" || _ftq_fn=""
			case "$_ftq_fn" in ''|NOTFOUND|null) _ftq_fn="document.bin" ;; esac
			_ftq_kind="document" _ftq_ty=4 _ftq_lbl="文件"
			;;
		esac
	fi

	case "$_ftq_fid" in ''|NOTFOUND|null) return 1 ;; esac

	mkdir -p /tmp/img 2>/dev/null
	_tg_download_file "$_ftq_fid" "qqbot-tg-$_ftq_kind" "tg->qqbot $_ftq_kind" \
		|| { log_err "sync: tg→qqbot $_ftq_kind download FAIL: $_ERROR"; return 1; }
	_ftq_tmp="$_tg_df_path"

	_ftq_sz="$(wc -c <"$_ftq_tmp" 2>/dev/null | tr -d ' ')"
	_ftq_max="${QQBOT_FILE_DATA_MAX:-5242880}"
	if [ -n "$_ftq_sz" ] && [ "$_ftq_sz" -gt "$_ftq_max" ] 2>/dev/null; then
		log_warn "sync: tg→qqbot $_ftq_kind skipped, $_ftq_sz bytes > ${_ftq_max} file_data cap"
		rm -f "$_ftq_tmp"
		return 1
	fi

	_ftq_cap="✈️ $_ftq_sender: [$_ftq_lbl]"
	# The send helpers run inside $(), so $QQBOT_ERR_FILE carries the reason out.
	_ftq_erf="/tmp/qqbot-err.$$"; : >"$_ftq_erf"
	QQBOT_ERR_FILE="$_ftq_erf" _ERROR=""
	case "$_ftq_tid" in
	group/*)
		if qqbot_send_group_file_typed "${_ftq_tid#group/}" "$_ftq_tmp" "$_ftq_ty" "$_ftq_fn" "$_ftq_cap" >/dev/null 2>/dev/null; then
			log_info "sync: tg→qqbot group ${_ftq_tid#group/} $_ftq_kind OK (type=$_ftq_ty)"
			_ftq_rc=0
		else
			_ftq_rc=1
		fi
		;;
	private/*)
		if qqbot_send_c2c_file_typed "${_ftq_tid#private/}" "$_ftq_tmp" "$_ftq_ty" "$_ftq_fn" "$_ftq_cap" >/dev/null 2>/dev/null; then
			log_info "sync: tg→qqbot private ${_ftq_tid#private/} $_ftq_kind OK (type=$_ftq_ty)"
			_ftq_rc=0
		else
			_ftq_rc=1
		fi
		;;
	*)
		_ftq_rc=1
		;;
	esac
	if [ "$_ftq_rc" != "0" ]; then
		_ftq_err="$(tail -n 1 "$_ftq_erf" 2>/dev/null)"
		[ -n "$_ftq_err" ] || _ftq_err="$_ERROR"
		log_err "sync: tg→qqbot $_ftq_tid $_ftq_kind FAIL (type=$_ftq_ty): ${_ftq_err:-no detail}"
	fi
	unset QQBOT_ERR_FILE
	rm -f "$_ftq_tmp" "$_ftq_erf"
	return "$_ftq_rc"
}
