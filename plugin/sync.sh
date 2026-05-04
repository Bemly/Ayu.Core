# plugin/sync.sh — cross-platform message sync
# Forwards messages between QQ, Telegram, Discord based on etc/sync.conf
# Called by dispatch: sync_handler <pf> <evt> <uid> <txt> <raw>

[ -z "${_HB:-}" ] && _HB="$(pwd)"

# Source message APIs (harmless if already sourced)
. "$_HB/adapter/qq/message.sh"
. "$_HB/adapter/qq/file.sh"
. "$_HB/adapter/telegram/message.sh"
. "$_HB/adapter/telegram/file.sh"
. "$_HB/adapter/discord/message.sh"

# Extract sender display name from platform-specific raw JSON
_sync_get_sender() {
	_pf="$1" _raw="$2"
	case "$_pf" in
	qq)
		_gm="$(json_get "$_raw" group_member)"
		if [ -n "$_gm" ] && [ "$_gm" != "NOTFOUND" ]; then
			_nm="$(json_get "$_gm" nickname)"
			[ -n "$_nm" ] && [ "$_nm" != "NOTFOUND" ] && { printf '%s' "$_nm"; return; }
			_nm="$(json_get "$_gm" card)"
			[ -n "$_nm" ] && [ "$_nm" != "NOTFOUND" ] && { printf '%s' "$_nm"; return; }
		fi
		_fr="$(json_get "$_raw" friend)"
		if [ -n "$_fr" ] && [ "$_fr" != "NOTFOUND" ]; then
			_nm="$(json_get "$_fr" nickname)"
			[ -n "$_nm" ] && [ "$_nm" != "NOTFOUND" ] && { printf '%s' "$_nm"; return; }
		fi
		json_get "$_raw" sender_id
		;;
	telegram)
		_from="$(json_get "$_raw" from)"
		if [ -n "$_from" ] && [ "$_from" != "NOTFOUND" ]; then
			_fn="$(json_get "$_from" first_name)"
			_ln="$(json_get "$_from" last_name)"
			if [ -n "$_fn" ] && [ "$_fn" != "NOTFOUND" ]; then
				if [ -n "$_ln" ] && [ "$_ln" != "NOTFOUND" ]; then
					printf '%s %s' "$_fn" "$_ln"
				else
					printf '%s' "$_fn"
				fi
				return
			fi
			_un="$(json_get "$_from" username)"
			[ -n "$_un" ] && [ "$_un" != "NOTFOUND" ] && { printf '@%s' "$_un"; return; }
		fi
		printf 'unknown'
		;;
	*) printf 'unknown' ;;
	esac
}

# Extract source chat/channel/group ID as config lookup key
_sync_source_id() {
	_pf="$1" _raw="$2"
	case "$_pf" in
	qq)
		# message_receive: group_id is nested in group.group_id
		_group="$(json_get "$_raw" group 2>/dev/null)" || _group=""
		if [ -n "$_group" ] && [ "$_group" != "NOTFOUND" ]; then
			_gid="$(json_get "$_group" group_id 2>/dev/null)" || _gid=""
			if [ -n "$_gid" ] && [ "$_gid" != "NOTFOUND" ]; then
				printf 'group/%s' "$_gid"; return
			fi
		fi
		# non-message events: group_id at top level
		_gid="$(json_get "$_raw" group_id 2>/dev/null)" || _gid=""
		if [ -n "$_gid" ] && [ "$_gid" != "NOTFOUND" ]; then
			printf 'group/%s' "$_gid"; return
		fi
		# private messages
		_pid="$(json_get "$_raw" peer_id 2>/dev/null)" || _pid=""
		[ -n "$_pid" ] && [ "$_pid" != "NOTFOUND" ] && printf 'private/%s' "$_pid"
		;;
	telegram)
		_chat="$(json_get "$_raw" chat 2>/dev/null)" || _chat=""
		if [ -n "$_chat" ] && [ "$_chat" != "NOTFOUND" ]; then
			_cid="$(json_get "$_chat" id 2>/dev/null)" || _cid=""
			printf '%s' "$_cid"
		fi
		;;
	esac
}

# Upload file to Telegram via multipart/form-data
_sync_tg_multipart() {
	_chat="$1" _thr="$2" _file="$3" _fname="$4" _cap="$5"
	_bound="ayu-$$-$(date +%s)"
	_tmp="/tmp/tg-up-$$"
	# Build multipart body
	> "$_tmp"
	printf '--%s\r\n' "$_bound" >> "$_tmp"
	printf 'Content-Disposition: form-data; name="chat_id"\r\n\r\n' >> "$_tmp"
	printf '%s\r\n' "$_chat" >> "$_tmp"
	printf '--%s\r\n' "$_bound" >> "$_tmp"
	printf 'Content-Disposition: form-data; name="photo"; filename="%s"\r\n' "$_fname" >> "$_tmp"
	printf 'Content-Type: application/octet-stream\r\n\r\n' >> "$_tmp"
	cat "$_file" >> "$_tmp"
	printf '\r\n' >> "$_tmp"
	if [ -n "$_cap" ]; then
		printf '--%s\r\n' "$_bound" >> "$_tmp"
		printf 'Content-Disposition: form-data; name="caption"\r\n\r\n' >> "$_tmp"
		printf '%s\r\n' "$_cap" >> "$_tmp"
	fi
	if [ -n "$_thr" ]; then
		printf '--%s\r\n' "$_bound" >> "$_tmp"
		printf 'Content-Disposition: form-data; name="message_thread_id"\r\n\r\n' >> "$_tmp"
		printf '%s\r\n' "$_thr" >> "$_tmp"
	fi
	printf '--%s--\r\n' "$_bound" >> "$_tmp"
	# Send
	_url="${TG_API_BASE}/sendPhoto"
	if http_post_file "$_url" "$_tmp" \
		"Content-Type: multipart/form-data; boundary=$_bound" \
		"X-Ayu-Token: ${TG_API_SECRET}" >/dev/null; then
		rm -f "$_tmp"; return 0
	else
		rm -f "$_tmp"; return 1
	fi
}

# Forward QQ images to TG (GIF→sendAnimation, static→sendPhoto)
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
				"X-Ayu-Token: ${TG_API_SECRET}" >/dev/null; then
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
			"X-Ayu-Token: ${TG_API_SECRET}" >/dev/null; then
			_sent=$((_sent + 1)); log_info "sync: qq→tg file OK"
		else
			log_err "sync: qq→tg file FAIL: $_ERROR"
		fi
		rm -f "$_ltmp" "$_mtmp"
	done
	log_info "sync: qq→tg files sent=$_sent"
	[ $_sent -gt 0 ] && return 0 || return 1
}

# Forward TG photo to QQ (download from TG via CF Worker, upload to QQ)
_sync_tg_photo_to_qq() {
	_raw="$1" _gid="$2"
	_photos="$(json_get "$_raw" photo 2>/dev/null)" || return 1
	if [ -z "$_photos" ] || [ "$_photos" = "NOTFOUND" ]; then return 1; fi
	_fid="$(printf '%s' "$_photos" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p' | tail -1)"
	if [ -z "$_fid" ]; then return 1; fi
	_fp="$(tg_getFile "$_fid" 2>/dev/null)" || _fp=""
	if [ -z "$_fp" ] || [ "$_fp" = "NOTFOUND" ]; then
		log_err "sync: tg→qq getFile FAIL"; return 1
	fi
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

# Forward TG animation (GIF) to QQ (download from TG via CF Worker, upload to QQ)
_sync_tg_animation_to_qq() {
	_raw="$1" _gid="$2"
	_ani="$(json_get "$_raw" animation 2>/dev/null)" || return 1
	if [ -z "$_ani" ] || [ "$_ani" = "NOTFOUND" ]; then return 1; fi
	_fid="$(printf '%s' "$_ani" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p' | tail -1)"
	if [ -z "$_fid" ]; then return 1; fi
	_fp="$(tg_getFile "$_fid" 2>/dev/null)" || _fp=""
	if [ -z "$_fp" ] || [ "$_fp" = "NOTFOUND" ]; then
		log_err "sync: tg→qq animation getFile FAIL"; return 1
	fi
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
	# Build image segment array → send via send_group_message
	_img_msg="[{\"type\":\"image\",\"data\":{\"uri\":\"$_furi\",\"summary\":\"[动画]\"}}]"
	if qq_message_send_group "$_gid" "$_img_msg" >/dev/null; then
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
	_fp="$(tg_getFile "$_fid" 2>/dev/null)" || _fp=""
	if [ -z "$_fp" ] || [ "$_fp" = "NOTFOUND" ]; then
		log_err "sync: tg→qq file getFile FAIL"; return 1
	fi
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
sync_handler() {
	_pf="$1" _evt="$2" _uid="$3" _txt="$4" _raw="$5"

	# Loop prevention 1: emoji prefix = already forwarded
	case "$_txt" in "🐧"*|"✈️"*|"👾"*) return 0 ;; esac
	# Loop prevention 2: sender is the bot itself
	case "$_pf" in
		qq) [ "$_uid" = "3156037162" ] && return 0 ;;
		telegram)
			_fid="$(json_get "$_raw" from 2>/dev/null)" || _fid=""
			if [ -n "$_fid" ] && [ "$_fid" != "NOTFOUND" ]; then
				_fid_id="$(json_get "$_fid" id 2>/dev/null)" || _fid_id=""
				[ "$_fid_id" = "8723729335" ] && return 0
			fi
			;;
	esac

	# Decode \uXXXX to UTF-8
	_txt="$(utf8_decode "$_txt")"

	# Map non-message events to descriptive text
	case "$_evt" in
		group_nudge) _txt="[戳一戳]" ;;
		member_join) _txt="[新成员加入]" ;;
		member_leave) _txt="[成员离开]" ;;
		friend_request) _txt="[好友请求]" ;;
		message_recall) _txt="[撤回消息]" ;;
	esac

	_conf="${_SYNC_CONF:-$_HB/etc/sync.conf}"
	if [ ! -f "$_conf" ]; then
		log_debug "sync: no conf at $_conf"
		return 0
	fi

	# Build prefixed text with sender attribution and emoji icon
	_sender="$(_sync_get_sender "$_pf" "$_raw")"
	_sender="$(utf8_decode "$_sender")"
	case "$_pf" in qq) _icon="🐧" ;; telegram) _icon="✈️" ;; discord) _icon="👾" ;; *) _icon="[$_pf]" ;; esac
	_text="$_icon $_sender: $_txt"

	# Extract source ID for config lookup
	_src_id="$(_sync_source_id "$_pf" "$_raw")"
	if [ -z "$_src_id" ]; then
		log_debug "sync: no src_id pf=$_pf"
		return 0
	fi

	log_info "sync: $_pf $_src_id → $_txt"

	# Pre-build platform-specific payloads
	_segs="$(qq_text_segments "$_text")"
	_dc_body="$(json_obj "content" "$_text")"

	_found=0
	while IFS='=' read -r _src _tgt; do
		case "$_src" in \#*|"") continue ;; esac
		_spf="${_src%%/*}"
		_sid="${_src#*/}"
		[ "$_spf" != "$_pf" ] && continue
		[ "$_sid" != "$_src_id" ] && continue

		_tpf="${_tgt%%/*}"
		_tid="${_tgt#*/}"
		_found=1

		case "$_tpf" in
		telegram)
			_tcid="${_tid%%/*}"
			_tthr="${_tid#*/}"
			[ "$_tthr" = "$_tcid" ] && _tthr=""
			if [ -n "$_tthr" ]; then
				_body="$(json_obj "chat_id" "$_tcid" "text" "$_text" "message_thread_id" "$_tthr")"
			else
				_body="$(json_obj "chat_id" "$_tcid" "text" "$_text")"
			fi
			if _tg_api "sendMessage" "$_body" "sync.tg" >/dev/null; then
				log_info "sync: $_pf→tg OK"
			else
				log_err "sync: $_pf→tg FAIL: $_ERROR"
			fi
			# Forward images (QQ→TG)
			if [ "$_pf" = "qq" ]; then
				_sync_qq_images_to_tg "$_raw" "$_tcid" "$_tthr" "$_sender"
				_sync_qq_files_to_tg "$_raw" "$_tcid" "$_tthr" "$_sender" "${_sid#group/}"
			fi
			;;
		qq)
			case "$_tid" in
			group/*)
				_gid="${_tid#group/}"
				if qq_message_send_group "$_gid" "$_segs" >/dev/null; then
					log_info "sync: $_pf→qq group $_gid OK"
				else
					log_err "sync: $_pf→qq group $_gid FAIL: $_ERROR"
				fi
				# Forward photo (TG→QQ)
				if [ "$_pf" = "telegram" ]; then
					_sync_tg_photo_to_qq "$_raw" "$_gid"
				_sync_tg_animation_to_qq "$_raw" "$_gid"
				_sync_tg_document_to_qq "$_raw" "$_gid"
				fi
				;;
			private/*)
				_pid="${_tid#private/}"
				if qq_message_send_private "$_pid" "$_segs" >/dev/null; then
					log_info "sync: $_pf→qq private $_pid OK"
				else
					log_err "sync: $_pf→qq private $_pid FAIL: $_ERROR"
				fi
				;;
			esac
			;;
		discord)
			if dc_message_create "$_tid" "$_dc_body" >/dev/null; then
				log_info "sync: $_pf→dc OK"
			else
				log_err "sync: $_pf→dc FAIL: $_ERROR"
			fi
			;;
		esac
	done < "$_conf"

	[ $_found -eq 0 ] && log_debug "sync: no match for $_pf $_src_id"
	return 0
}
