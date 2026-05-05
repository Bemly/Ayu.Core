_sync_qq_images_to_tg() {
	_raw="$1" _tcid="$2" _tthr="$3" _sender="$4"
	_segs="$(json_get "$_raw" segments 2>/dev/null)" || _segs=""
	if [ -z "$_segs" ] || [ "$_segs" = "NOTFOUND" ]; then return 1; fi
	# Split segments and filter image type (check sub_type for GIF)
	_imgs="$(printf '%s' "$_segs" | sed 's/},{"type"/\
{"type"/g' | grep '"type":"image"')"
	if [ -z "$_imgs" ]; then
		log_info "sync: img segs=$(printf '%.200s' "$_segs")"
		return 1
	fi
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
			# GIF → sendAnimation (upload via multipart)
			_bound="ayu-$$-$_ts"
			_mtmp="/tmp/tg-gif-up-$$"
			> "$_mtmp"
			printf '--%s\r\n' "$_bound" >> "$_mtmp"
			printf 'Content-Disposition: form-data; name="chat_id"\r\n\r\n' >> "$_mtmp"
			printf '%s\r\n' "$_tcid" >> "$_mtmp"
			if [ -n "$_tthr" ]; then
				printf '--%s\r\n' "$_bound" >> "$_mtmp"
				printf 'Content-Disposition: form-data; name="message_thread_id"\r\n\r\n' >> "$_mtmp"
				printf '%s\r\n' "$_tthr" >> "$_mtmp"
			fi
			printf '--%s\r\n' "$_bound" >> "$_mtmp"
			printf 'Content-Disposition: form-data; name="animation"; filename="qq-gif.gif"\r\n' >> "$_mtmp"
			printf 'Content-Type: image/gif\r\n\r\n' >> "$_mtmp"
			cat "$_tmp" >> "$_mtmp"
			printf '\r\n--%s--\r\n' "$_bound" >> "$_mtmp"
			_url="${TG_API_BASE}/sendAnimation"
			if http_post_file "$_url" "$_mtmp" \
				"Content-Type: multipart/form-data; boundary=$_bound" \
				"$_TG_AUTH" >/dev/null; then
				_sent=$((_sent + 1)); log_info "sync: qq→tg GIF OK"
			else
				log_err "sync: qq→tg GIF FAIL: $_ERROR"
			fi
			rm -f "$_mtmp"
		else
			# Static image → sendPhoto with URL
			rm -f "$_tmp"
			if [ -n "$_tthr" ]; then
				_body="$(json_obj "chat_id" "$_tcid" "photo" "$_url" "caption" "🐧 $_sender: [图片]" "message_thread_id" "$_tthr")"
			else
				_body="$(json_obj "chat_id" "$_tcid" "photo" "$_url" "caption" "🐧 $_sender: [图片]")"
			fi
			if _tg_api "sendPhoto" "$_body" "sync.img" >/dev/null; then
				_sent=$((_sent + 1)); log_info "sync: qq→tg image OK"
			else
				log_err "sync: qq→tg image FAIL: $_ERROR"
			fi
		fi
		rm -f "$_tmp"
	done
	log_info "sync: qq→tg images sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward QQ files to TG (download, then multipart upload via sendDocument)
_sync_qq_files_to_tg() {
	_raw="$1" _tcid="$2" _tthr="$3" _sender="$4" _gid="$5"
	_segs="$(json_get "$_raw" segments 2>/dev/null)" || _segs=""
	if [ -z "$_segs" ] || [ "$_segs" = "NOTFOUND" ]; then return 1; fi
	_files="$(printf '%s' "$_segs" | sed 's/},{"type"/\
{"type"/g' | grep '"type":"file"')"
	if [ -z "$_files" ]; then return 1; fi
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
		# Multipart upload to TG via sendDocument
		_bound="ayu-$$-$_ts"
		_mtmp="/tmp/tg-up-$$"
		> "$_mtmp"
		printf '--%s\r\n' "$_bound" >> "$_mtmp"
		printf 'Content-Disposition: form-data; name="chat_id"\r\n\r\n' >> "$_mtmp"
		printf '%s\r\n' "$_tcid" >> "$_mtmp"
		if [ -n "$_tthr" ]; then
			printf '--%s\r\n' "$_bound" >> "$_mtmp"
			printf 'Content-Disposition: form-data; name="message_thread_id"\r\n\r\n' >> "$_mtmp"
			printf '%s\r\n' "$_tthr" >> "$_mtmp"
		fi
		printf '--%s\r\n' "$_bound" >> "$_mtmp"
		printf 'Content-Disposition: form-data; name="document"; filename="%s"\r\n' "$_fn" >> "$_mtmp"
		printf 'Content-Type: application/octet-stream\r\n\r\n' >> "$_mtmp"
		cat "$_ltmp" >> "$_mtmp"
		printf '\r\n' >> "$_mtmp"
		printf '--%s--\r\n' "$_bound" >> "$_mtmp"
		_url="${TG_API_BASE}/sendDocument"
		if http_post_file "$_url" "$_mtmp" \
			"Content-Type: multipart/form-data; boundary=$_bound" \
			"$_TG_AUTH" >/dev/null; then
			_sent=$((_sent + 1)); log_info "sync: qq→tg file OK"
		else
			log_err "sync: qq→tg file FAIL: $_ERROR"
		fi
		rm -f "$_ltmp" "$_mtmp"
	done
	log_info "sync: qq→tg files sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}
# Forward QQ voice to TG (download record, multipart sendVoice)
_sync_qq_record_to_tg() {
	_raw="$1" _tcid="$2" _tthr="$3" _sender="$4"
	_segs="$(json_get "$_raw" segments 2>/dev/null)" || _segs=""
	if [ -z "$_segs" ] || [ "$_segs" = "NOTFOUND" ]; then return 1; fi
	_recs="$(printf '%s' "$_segs" | sed 's/},{"type"/\
{"type"/g' | grep '"type":"record"')"
	if [ -z "$_recs" ]; then return 1; fi
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
		_bound="ayu-$$-$_ts"
		_mtmp="/tmp/tg-voice-up-$$"
		> "$_mtmp"
		printf '--%s\r\n' "$_bound" >> "$_mtmp"
		printf 'Content-Disposition: form-data; name="chat_id"\r\n\r\n' >> "$_mtmp"
		printf '%s\r\n' "$_tcid" >> "$_mtmp"
		if [ -n "$_tthr" ]; then
			printf '--%s\r\n' "$_bound" >> "$_mtmp"
			printf 'Content-Disposition: form-data; name="message_thread_id"\r\n\r\n' >> "$_mtmp"
			printf '%s\r\n' "$_tthr" >> "$_mtmp"
		fi
		printf '--%s\r\n' "$_bound" >> "$_mtmp"
		printf 'Content-Disposition: form-data; name="voice"; filename="qq-voice.amr"\r\n' >> "$_mtmp"
		printf 'Content-Type: audio/amr\r\n\r\n' >> "$_mtmp"
		cat "$_tmp" >> "$_mtmp"
		printf '\r\n' >> "$_mtmp"
		[ -n "$_dur" ] && printf '--%s\r\nContent-Disposition: form-data; name="duration"\r\n\r\n%s\r\n' "$_bound" "$_dur" >> "$_mtmp"
		printf '--%s--\r\n' "$_bound" >> "$_mtmp"
		_url="${TG_API_BASE}/sendVoice"
		if http_post_file "$_url" "$_mtmp" \
			"Content-Type: multipart/form-data; boundary=$_bound" \
			"$_TG_AUTH" >/dev/null; then
			_sent=$((_sent + 1)); log_info "sync: qq-tg voice OK"
		else
			log_err "sync: qq-tg voice FAIL: $_ERROR"
		fi
		rm -f "$_tmp" "$_mtmp"
	done
	log_info "sync: qq-tg voice sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward QQ video to TG (download, multipart sendVideo)
_sync_qq_video_to_tg() {
	_raw="$1" _tcid="$2" _tthr="$3" _sender="$4"
	_segs="$(json_get "$_raw" segments 2>/dev/null)" || _segs=""
	if [ -z "$_segs" ] || [ "$_segs" = "NOTFOUND" ]; then return 1; fi
	_vids="$(printf '%s' "$_segs" | sed 's/},{"type"/\
{"type"/g' | grep '"type":"video"')"
	if [ -z "$_vids" ]; then return 1; fi
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
		_bound="ayu-$$-$_ts"
		_mtmp="/tmp/tg-video-up-$$"
		> "$_mtmp"
		printf '--%s\r\n' "$_bound" >> "$_mtmp"
		printf 'Content-Disposition: form-data; name="chat_id"\r\n\r\n' >> "$_mtmp"
		printf '%s\r\n' "$_tcid" >> "$_mtmp"
		if [ -n "$_tthr" ]; then
			printf '--%s\r\n' "$_bound" >> "$_mtmp"
			printf 'Content-Disposition: form-data; name="message_thread_id"\r\n\r\n' >> "$_mtmp"
			printf '%s\r\n' "$_tthr" >> "$_mtmp"
		fi
		printf '--%s\r\n' "$_bound" >> "$_mtmp"
		printf 'Content-Disposition: form-data; name="video"; filename="qq-video.mp4"\r\n' >> "$_mtmp"
		printf 'Content-Type: video/mp4\r\n\r\n' >> "$_mtmp"
		cat "$_tmp" >> "$_mtmp"
		printf '\r\n--%s--\r\n' "$_bound" >> "$_mtmp"
		_url="${TG_API_BASE}/sendVideo"
		if http_post_file "$_url" "$_mtmp" \
			"Content-Type: multipart/form-data; boundary=$_bound" \
			"$_TG_AUTH" >/dev/null; then
			_sent=$((_sent + 1)); log_info "sync: qq-tg video OK"
		else
			log_err "sync: qq-tg video FAIL: $_ERROR"
		fi
		rm -f "$_tmp" "$_mtmp"
	done
	log_info "sync: qq-tg video sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward QQ images to DC (download, multipart POST)
_sync_qq_images_to_dc() {
	_raw="$1" _cid="$2" _sender="$3"
	_segs="$(json_get "$_raw" segments 2>/dev/null)" || _segs=""
	if [ -z "$_segs" ] || [ "$_segs" = "NOTFOUND" ]; then return 1; fi
	_imgs="$(printf '%s' "$_segs" | sed 's/},{"type"/\
{"type"/g' | grep '"type":"image"')"
	if [ -z "$_imgs" ]; then return 1; fi
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
	_segs="$(json_get "$_raw" segments 2>/dev/null)" || _segs=""
	if [ -z "$_segs" ] || [ "$_segs" = "NOTFOUND" ]; then return 1; fi
	_files="$(printf '%s' "$_segs" | sed 's/},{"type"/\
{"type"/g' | grep '"type":"file"')"
	if [ -z "$_files" ]; then return 1; fi
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
	_segs="$(json_get "$_raw" segments 2>/dev/null)" || _segs=""
	if [ -z "$_segs" ] || [ "$_segs" = "NOTFOUND" ]; then return 1; fi
	_recs="$(printf '%s' "$_segs" | sed 's/},{"type"/\
{"type"/g' | grep '"type":"record"')"
	if [ -z "$_recs" ]; then return 1; fi
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
	_segs="$(json_get "$_raw" segments 2>/dev/null)" || _segs=""
	if [ -z "$_segs" ] || [ "$_segs" = "NOTFOUND" ]; then return 1; fi
	_vids="$(printf '%s' "$_segs" | sed 's/},{"type"/\
{"type"/g' | grep '"type":"video"')"
	if [ -z "$_vids" ]; then return 1; fi
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
