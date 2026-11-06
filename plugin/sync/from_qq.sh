_sync_qq_images_to_tg() {
	_raw="$1" _tcid="$2" _tthr="$3" _sender="$4"
	_imgs="$(_qq_extract_segments "$_raw" "image")" || return 1
	_sent=0
	IFS='
'
	for _img in $_imgs; do
		_url="$(printf '%s' "$_img" | sed -n 's/.*"temp_url":"\([^"]*\)".*/\1/p')"
		[ -z "$_url" ] && continue
		_url="$(utf8_decode "$_url")"
		# No sub_type from QQ — detect GIF by downloading and checking magic bytes
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-qq-$$-$_ts"
		http_get_file "$_url" "$_tmp" || {
			# Download failed, fallback to sendPhoto with URL
			log_err "sync: qq→tg download FAIL, trying URL"; rm -f "$_tmp"
			if [ -n "$_tthr" ]; then
				_body="$(json_obj "chat_id" "$_tcid" "photo" "$_url" "caption" "🐧 $_sender: [图片]" "message_thread_id" "$_tthr")"
			else
				_body="$(json_obj "chat_id" "$_tcid" "photo" "$_url" "caption" "🐧 $_sender: [图片]")"
			fi
			_tg_api "sendPhoto" "$_body" "sync.img" >/dev/null && _sent=$((_sent + 1))
			continue
		}
		# Check GIF magic bytes (GIF87a or GIF89a)
		_magic="$(dd if="$_tmp" bs=3 count=1 2>/dev/null)"
		log_debug "sync: img url=[$_url] magic=[$_magic] sz=$(wc -c <"$_tmp" 2>/dev/null)"
		if [ "$_magic" = "GIF" ]; then
			if _sync_tg_multipart "$_tcid" "$_tthr" "$_tmp" "qq-gif.gif" "sendAnimation" "animation" "image/gif"; then
				_sent=$((_sent + 1)); log_info "sync: qq→tg GIF OK"
			else
				log_err "sync: qq→tg GIF FAIL: $_ERROR"
			fi
			rm -f "$_tmp"
		else
			# Static image → upload the bytes we already downloaded.
			# (Sending Telegram the QQ CDN link only works while the temp URL is
			# alive and anonymous, so it is kept as a fallback, not the main path.)
			_sz="$(wc -c <"$_tmp" 2>/dev/null)"
			_magic2="$(dd if="$_tmp" bs=2 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
			_ext="jpg" _mime="image/jpeg"
			case "$_magic2" in
				8950) _ext="png" _mime="image/png" ;;
				5249) _ext="webp" _mime="image/webp" ;;
			esac
			_cap="🐧 $_sender: [图片]"
			if [ "${_sz:-0}" -gt 10000000 ] 2>/dev/null; then
				# Telegram photo limit is 10 MB — send as a document instead of failing
				_sync_tg_multipart "$_tcid" "$_tthr" "$_tmp" "qq-image.$_ext" "sendDocument" "document" "$_mime" "$_cap"
			else
				_sync_tg_multipart "$_tcid" "$_tthr" "$_tmp" "qq-image.$_ext" "sendPhoto" "photo" "$_mime" "$_cap"
			fi
			_rc=$?
			if [ $_rc -eq 0 ]; then
				_sent=$((_sent + 1)); log_info "sync: qq→tg image OK"
			else
				log_err "sync: qq→tg image upload FAIL, falling back to url: $_ERROR"
				if [ -n "$_tthr" ]; then
					_body="$(json_obj "chat_id" "$_tcid" "photo" "$_url" "caption" "$_cap" "message_thread_id" "$_tthr")"
				else
					_body="$(json_obj "chat_id" "$_tcid" "photo" "$_url" "caption" "$_cap")"
				fi
				_tg_api "sendPhoto" "$_body" "sync.img" >/dev/null && _sent=$((_sent + 1))
			fi
			rm -f "$_tmp"
		fi
		rm -f "$_tmp"
	done
	log_info "sync: qq→tg images sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward QQ files to TG (download, then multipart upload via sendDocument)
_sync_qq_files_to_tg() {
	_raw="$1" _tcid="$2" _tthr="$3" _sender="$4" _gid="$5"
	_files="$(_qq_extract_segments "$_raw" "file")" || return 1
	_sent=0
	IFS='
'
	for _f in $_files; do
		_fid="$(printf '%s' "$_f" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p')"
		_fn="$(printf '%s' "$_f" | sed -n 's/.*"file_name":"\([^"]*\)".*/\1/p')"
		[ -z "$_fid" ] && continue
		_fn="$(utf8_decode "$_fn")"
		_dl="$(qq_file_get_download_url "$_gid" "$_fid" 2>/dev/null)" || _dl=""
		if [ -z "$_dl" ] || [ "$_dl" = "NOTFOUND" ]; then
			log_err "sync: qq→tg file no url fid=$_fid dl=[$_dl]"; continue
		fi
		_url="$(json_get "$_dl" download_url 2>/dev/null)" || _url=""
		[ -z "$_url" ] && _url="$_dl"
		_url="$(utf8_decode "$_url")"
		# Download file from QQ CDN
		_ts=$(date +%s)
		_ext="${_fn##*.}"
		[ "$_ext" = "$_fn" ] && _ext=""
		[ -n "$_ext" ] && _ext=".$_ext"
		_ltmp="/tmp/img/sync-file-qq-$$-$_ts$_ext"
		http_get_file "$_url" "$_ltmp" || {
			log_err "sync: qq→tg file download FAIL"; rm -f "$_ltmp"; continue
		}
		if _sync_tg_multipart "$_tcid" "$_tthr" "$_ltmp" "$_fn" "sendDocument" "document"; then
			_sent=$((_sent + 1)); log_info "sync: qq→tg file OK"
		else
			log_err "sync: qq→tg file FAIL: $_ERROR"
		fi
		rm -f "$_ltmp"
	done
	log_info "sync: qq→tg files sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}
# Forward QQ voice to TG (download record, multipart sendVoice)
_sync_qq_record_to_tg() {
	_raw="$1" _tcid="$2" _tthr="$3" _sender="$4"
	_recs="$(_qq_extract_segments "$_raw" "record")" || return 1
	_sent=0
	IFS='
'
	for _rec in $_recs; do
		_url="$(printf '%s' "$_rec" | sed -n 's/.*"temp_url":"\([^"]*\)".*/\1/p')"
		[ -z "$_url" ] && continue
		_url="$(utf8_decode "$_url")"
		_dur="$(printf '%s' "$_rec" | sed -n 's/.*"duration":\([0-9]*\).*/\1/p')"
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-voice-qq-$$-$_ts.amr"
		http_get_file "$_url" "$_tmp" || { log_err "sync: voice download FAIL"; rm -f "$_tmp"; continue; }
		if _sync_tg_multipart "$_tcid" "$_tthr" "$_tmp" "qq-voice.amr" "sendVoice" "voice" "audio/amr" "" "$_dur"; then
			_sent=$((_sent + 1)); log_info "sync: qq-tg voice OK"
		else
			log_err "sync: qq-tg voice FAIL: $_ERROR"
		fi
		rm -f "$_tmp"	rm -f "$_tmp" "$_mtmp"
	done
	log_info "sync: qq-tg voice sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward QQ video to TG (download, multipart sendVideo)
_sync_qq_video_to_tg() {
	_raw="$1" _tcid="$2" _tthr="$3" _sender="$4"
	_vids="$(_qq_extract_segments "$_raw" "video")" || return 1
	_sent=0
	IFS='
'
	for _vid in $_vids; do
		_url="$(printf '%s' "$_vid" | sed -n 's/.*"temp_url":"\([^"]*\)".*/\1/p')"
		[ -z "$_url" ] && continue
		_url="$(utf8_decode "$_url")"
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-video-qq-$$-$_ts"
		http_get_file "$_url" "$_tmp" || { log_err "sync: video download FAIL"; rm -f "$_tmp"; continue; }
		if _sync_tg_multipart "$_tcid" "$_tthr" "$_tmp" "qq-video.mp4" "sendVideo" "video" "video/mp4"; then
			_sent=$((_sent + 1)); log_info "sync: qq-tg video OK"
		else
			log_err "sync: qq-tg video FAIL: $_ERROR"
		fi
		rm -f "$_tmp"
	done
	log_info "sync: qq-tg video sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward QQ images to DC (download, multipart POST)
_sync_qq_images_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_imgs="$(_qq_extract_segments "$_raw" "image")" || return 1
	_sent=0
	IFS='
'
	for _img in $_imgs; do
		_url="$(printf '%s' "$_img" | sed -n 's/.*"temp_url":"\([^"]*\)".*/\1/p')"
		[ -z "$_url" ] && continue
		_url="$(utf8_decode "$_url")"
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-dc-qq-img-$$-$_ts"
		http_get_file "$_url" "$_tmp" || { log_err "sync: qq->dc img download FAIL"; rm -f "$_tmp"; continue; }
		_magic="$(dd if="$_tmp" bs=3 count=1 2>/dev/null)"
		if [ "$_magic" = "GIF" ]; then
			_mime="image/gif" _ext="gif"
		else
			_mime="image/png" _ext="png"
		fi
		if _sync_dc_multipart "$_cid" "$_tmp" "qq-image.$_ext" "$_mime" "🐧 $_sender: [图片]"; then
			_sent=$((_sent + 1)); log_info "sync: qq->dc image OK"
		else
			log_err "sync: qq->dc image FAIL: $_ERROR"
		fi
		rm -f "$_tmp"
	done
	log_info "sync: qq->dc images sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward QQ files to DC (download, multipart POST)
_sync_qq_files_to_dc() {
	_raw="$1" _cid="$2" _sender="$3" _gid="$4"
	_files="$(_qq_extract_segments "$_raw" "file")" || return 1
	_sent=0
	IFS='
'
	for _f in $_files; do
		_fid="$(printf '%s' "$_f" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p')"
		_fn="$(printf '%s' "$_f" | sed -n 's/.*"file_name":"\([^"]*\)".*/\1/p')"
		[ -z "$_fid" ] && continue
		_fn="$(utf8_decode "$_fn")"
		_dl="$(qq_file_get_download_url "$_gid" "$_fid" 2>/dev/null)" || _dl=""
		if [ -z "$_dl" ] || [ "$_dl" = "NOTFOUND" ]; then
			log_err "sync: qq->dc file no url fid=$_fid"; continue
		fi
		_url="$(json_get "$_dl" download_url 2>/dev/null)" || _url=""
		[ -z "$_url" ] && _url="$_dl"
		_url="$(utf8_decode "$_url")"
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-dc-qq-file-$$-$_ts"
		http_get_file "$_url" "$_tmp" || { log_err "sync: qq->dc file download FAIL"; rm -f "$_tmp"; continue; }
		if _sync_dc_multipart "$_cid" "$_tmp" "$_fn" "application/octet-stream" "🐧 $_sender: [文件] $_fn"; then
			_sent=$((_sent + 1)); log_info "sync: qq->dc file OK"
		else
			log_err "sync: qq->dc file FAIL: $_ERROR"
		fi
		rm -f "$_tmp"
	done
	log_info "sync: qq->dc files sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward QQ voice to DC (download, multipart POST)
_sync_qq_record_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_recs="$(_qq_extract_segments "$_raw" "record")" || return 1
	_sent=0
	IFS='
'
	for _rec in $_recs; do
		_url="$(printf '%s' "$_rec" | sed -n 's/.*"temp_url":"\([^"]*\)".*/\1/p')"
		[ -z "$_url" ] && continue
		_url="$(utf8_decode "$_url")"
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-dc-qq-voice-$$-$_ts.amr"
		http_get_file "$_url" "$_tmp" || { log_err "sync: qq->dc voice download FAIL"; rm -f "$_tmp"; continue; }
		if _sync_dc_multipart "$_cid" "$_tmp" "qq-voice.amr" "audio/amr" "🐧 $_sender: [语音]"; then
			_sent=$((_sent + 1)); log_info "sync: qq->dc voice OK"
		else
			log_err "sync: qq->dc voice FAIL: $_ERROR"
		fi
		rm -f "$_tmp"
	done
	log_info "sync: qq->dc voice sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward QQ video to DC (download, multipart POST)
_sync_qq_video_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_vids="$(_qq_extract_segments "$_raw" "video")" || return 1
	_sent=0
	IFS='
'
	for _vid in $_vids; do
		_url="$(printf '%s' "$_vid" | sed -n 's/.*"temp_url":"\([^"]*\)".*/\1/p')"
		[ -z "$_url" ] && continue
		_url="$(utf8_decode "$_url")"
		_ts=$(date +%s)
		_tmp="/tmp/img/sync-dc-qq-video-$$-$_ts"
		http_get_file "$_url" "$_tmp" || { log_err "sync: qq->dc video download FAIL"; rm -f "$_tmp"; continue; }
		if _sync_dc_multipart "$_cid" "$_tmp" "qq-video.mp4" "video/mp4" "🐧 $_sender: [视频]"; then
			_sent=$((_sent + 1)); log_info "sync: qq->dc video OK"
		else
			log_err "sync: qq->dc video FAIL: $_ERROR"
		fi
		rm -f "$_tmp"
	done
	log_info "sync: qq->dc video sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward TG photo to QQ (download from TG via CF Worker, upload to QQ)
