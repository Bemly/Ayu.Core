# adapter/qqbot/message.sh — QQ Bot message / media APIs
#
# Endpoints (OpenAPI v2):
#   POST   /v2/groups/{group_openid}/messages
#   POST   /v2/users/{user_openid}/messages
#   POST   /v2/users/{user_openid}/stream_messages
#   DELETE /v2/groups/{group_openid}/messages/{message_id}
#   DELETE /v2/users/{user_openid}/messages/{message_id}
#   POST   /channels/{channel_id}/messages
#   POST   /v2/groups/{group_openid}/files
#   POST   /v2/users/{user_openid}/files
#
# Passive replies must echo msg_id (5 min window, max 4-5 replies per msg_id)
# and use an incrementing msg_seq; the platform rejects repeated msg_id+msg_seq.

. "$_HB/adapter/qqbot/core.sh"

# ---- body builders ------------------------------------------------------

# qqbot_body_text <content> [msg_id] [msg_seq]
qqbot_body_text() {
	if [ -n "${2:-}" ]; then
		json_obj msg_type 0 content "$1" msg_id "$2" msg_seq "${3:-1}"
	else
		json_obj msg_type 0 content "$1"
	fi
}

# qqbot_body_markdown <content> [msg_id] [msg_seq]
qqbot_body_markdown() {
	_qmmd="$(json_obj content "$1")"
	if [ -n "${2:-}" ]; then
		json_obj msg_type 2 markdown "$_qmmd" msg_id "$2" msg_seq "${3:-1}"
	else
		json_obj msg_type 2 markdown "$_qmmd"
	fi
}

# qqbot_body_media <file_info> [content] [msg_id] [msg_seq]
qqbot_body_media() {
	_qmmedia="$(json_obj file_info "$1")"
	if [ -n "${3:-}" ]; then
		json_obj msg_type 7 media "$_qmmedia" content "${2:-}" msg_id "$3" msg_seq "${4:-1}"
	else
		json_obj msg_type 7 media "$_qmmedia" content "${2:-}"
	fi
}

# ---- group --------------------------------------------------------------

# Every send wrapper keeps the API response on stdout (ids live there) and
# records the reply id for /recall. The reply scene decides the state bucket.

qqbot_message_send_group() {
	_qmg_r="$(_qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/messages" "$(qqbot_body_text "$2" "${3:-}" "${4:-}")" "qqbot.group.send")" || return 1
	qqbot_track_sent group "$1" "$_qmg_r"
	printf '%s' "$_qmg_r"
}
qqbot_message_send_group_raw()  {
	_qmgr_r="$(_qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/messages" "$2" "qqbot.group.send")" || return 1
	qqbot_track_sent group "$1" "$_qmgr_r"
	printf '%s' "$_qmgr_r"
}
qqbot_message_send_group_md()   {
	_qmgm_r="$(_qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/messages" "$(qqbot_body_markdown "$2" "${3:-}" "${4:-}")" "qqbot.group.send_md")" || return 1
	qqbot_track_sent group "$1" "$_qmgm_r"
	printf '%s' "$_qmgm_r"
}
qqbot_message_recall_group()    { _qqbot_api DELETE "/v2/groups/$(qqbot_seg "$1")/messages/$(qqbot_seg "$2")" "{}" "qqbot.group.recall" >/dev/null; }

# ---- c2c (single chat) --------------------------------------------------

qqbot_message_send_c2c() {
	_qmc_r="$(_qqbot_api POST "/v2/users/$(qqbot_seg "$1")/messages" "$(qqbot_body_text "$2" "${3:-}" "${4:-}")" "qqbot.c2c.send")" || return 1
	qqbot_track_sent c2c "$1" "$_qmc_r"
	printf '%s' "$_qmc_r"
}
qqbot_message_send_c2c_raw()    {
	_qmcr_r="$(_qqbot_api POST "/v2/users/$(qqbot_seg "$1")/messages" "$2" "qqbot.c2c.send")" || return 1
	qqbot_track_sent c2c "$1" "$_qmcr_r"
	printf '%s' "$_qmcr_r"
}
qqbot_message_send_c2c_md()     {
	_qmcm_r="$(_qqbot_api POST "/v2/users/$(qqbot_seg "$1")/messages" "$(qqbot_body_markdown "$2" "${3:-}" "${4:-}")" "qqbot.c2c.send_md")" || return 1
	qqbot_track_sent c2c "$1" "$_qmcm_r"
	printf '%s' "$_qmcm_r"
}
qqbot_message_recall_c2c()      { _qqbot_api DELETE "/v2/users/$(qqbot_seg "$1")/messages/$(qqbot_seg "$2")" "{}" "qqbot.c2c.recall" >/dev/null; }

# qqbot_message_stream_c2c <user_openid> <content> [msg_id] [msg_seq] [index] [stream_id] [state]
# state: 1 = generating, 2 = finished
qqbot_message_stream_c2c() {
	_qs_stream="$(json_obj state "${7:-1}" index "${5:-1}" id "${6:-}")"
	if [ -n "${3:-}" ]; then
		_qs_body="$(json_obj msg_type 0 content "$2" msg_id "$3" msg_seq "${4:-1}" stream "$_qs_stream")"
	else
		_qs_body="$(json_obj msg_type 0 content "$2" stream "$_qs_stream")"
	fi
	_qqbot_api POST "/v2/users/$(qqbot_seg "$1")/stream_messages" "$_qs_body" "qqbot.c2c.stream"
}

# ---- guild channel ------------------------------------------------------

qqbot_message_send_channel()    { _qqbot_api POST "/channels/$(qqbot_seg "$1")/messages" "$(qqbot_body_text "$2" "${3:-}" "${4:-}")" "qqbot.channel.send"; }
qqbot_message_send_channel_raw(){ _qqbot_api POST "/channels/$(qqbot_seg "$1")/messages" "$2" "qqbot.channel.send"; }

# ---- rich media ---------------------------------------------------------

# qqbot_file_upload_group <group_openid> <file_type> <url> [srv_send_msg]
# file_type: 1 image, 2 video, 3 voice, 4 file
qqbot_file_upload_group() {
	_qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/files" \
		"$(json_obj file_type "$2" url "$3" srv_send_msg "${4:-false}")" "qqbot.group.file"
}

qqbot_file_upload_c2c() {
	_qqbot_api POST "/v2/users/$(qqbot_seg "$1")/files" \
		"$(json_obj file_type "$2" url "$3" srv_send_msg "${4:-false}")" "qqbot.c2c.file"
}

# qqbot_message_send_group_media <group_openid> <file_info> [content] [msg_id] [msg_seq]
qqbot_message_send_group_media() {
	_qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/messages" \
		"$(qqbot_body_media "$2" "${3:-}" "${4:-}" "${5:-}")" "qqbot.group.media"
}

qqbot_message_send_c2c_media() {
	_qqbot_api POST "/v2/users/$(qqbot_seg "$1")/messages" \
		"$(qqbot_body_media "$2" "${3:-}" "${4:-}" "${5:-}")" "qqbot.c2c.media"
}

# ---- guild recall -------------------------------------------------------

qqbot_message_recall_channel() {
	_qqbot_api DELETE "/channels/$(qqbot_seg "$1")/messages/$(qqbot_seg "$2")?hidetip=false" "{}" "qqbot.channel.recall" >/dev/null
}

# ---- local-file upload (file_data, <= 5MB) ------------------------------
# The platform takes binary media either as a public URL or as a base64
# `file_data` field capped at 5MB; larger files need the chunked flow
# (upload_prepare + presigned PUT), which is not wired yet. Keeping this a
# plain base64 body means no extra dependency: /bin/base64 is a busybox applet.

QQBOT_FILE_DATA_MAX="${QQBOT_FILE_DATA_MAX:-5242880}"

# qqbot_file_type_of <path> → 1 image, 2 video, 3 voice, 4 file
qqbot_file_type_of() {
	case "$1" in
		*.png|*.PNG|*.jpg|*.JPG|*.jpeg|*.JPEG|*.gif|*.GIF|*.webp|*.WEBP|*.bmp|*.BMP) printf '1' ;;
		*.mp4|*.MP4|*.mov|*.MOV|*.mkv|*.MKV) printf '2' ;;
		*.silk|*.SILK|*.amr|*.AMR|*.mp3|*.MP3|*.wav|*.WAV|*.ogg|*.OGG|*.m4a|*.M4A) printf '3' ;;
		*) printf '4' ;;
	esac
}

# _qqbot_filedata_body <file_type> <path> <file_name> <srv_send_msg> → body file
_qqbot_filedata_body() {
	_qfb_t="$1" _qfb_p="$2" _qfb_n="$3" _qfb_s="$4"
	_qfb_out="/tmp/qqbot-filedata.$$"
	printf '{"file_type":%s,"file_name":' "$_qfb_t" >"$_qfb_out" || {
		_ERROR="qqbot.file: cannot stage body"; return 1
	}
	json_escape "$_qfb_n" >>"$_qfb_out"
	printf ',"srv_send_msg":%s,"file_data":"' "$_qfb_s" >>"$_qfb_out"
	base64 <"$_qfb_p" 2>/dev/null | tr -d '\n' >>"$_qfb_out" || {
		rm -f "$_qfb_out"; _ERROR="qqbot.file: base64 failed"; return 1
	}
	printf '"}' >>"$_qfb_out"
	printf '%s' "$_qfb_out"
}

# qqbot_file_upload_group_data <group_openid> <file_type> <path> [file_name] [srv_send_msg]
qqbot_file_upload_group_data() {
	_qgd_ty="$2" _qgd_p="$3" _qgd_n="${4:-}" _qgd_s="${5:-false}"
	[ -f "$_qgd_p" ] || { _ERROR="qqbot.group.file: no such file $_qgd_p"; return 1; }
	[ -n "$_qgd_n" ] || _qgd_n="${_qgd_p##*/}"
	_qgd_sz="$(wc -c <"$_qgd_p" 2>/dev/null)" || _qgd_sz=0
	if [ "${_qgd_sz:-0}" -gt "$QQBOT_FILE_DATA_MAX" ]; then
		_ERROR="qqbot.group.file: $_qgd_sz bytes > ${QQBOT_FILE_DATA_MAX} (file_data cap)"
		return 1
	fi
	_qgd_b="$(_qqbot_filedata_body "$_qgd_ty" "$_qgd_p" "$_qgd_n" "$_qgd_s")" || return 1
	_qgd_r="$(_qqbot_api_body "/v2/groups/$(qqbot_seg "$1")/files" "$_qgd_b" "qqbot.group.file")" || {
		_qgd_rc=$?; rm -f "$_qgd_b"; return $_qgd_rc
	}
	rm -f "$_qgd_b"
	[ "$_qgd_s" = "true" ] && qqbot_track_sent group "$1" "$_qgd_r"
	printf '%s' "$_qgd_r"
}

# qqbot_file_upload_c2c_data <user_openid> <file_type> <path> [file_name] [srv_send_msg]
qqbot_file_upload_c2c_data() {
	_qcd_ty="$2" _qcd_p="$3" _qcd_n="${4:-}" _qcd_s="${5:-false}"
	[ -f "$_qcd_p" ] || { _ERROR="qqbot.c2c.file: no such file $_qcd_p"; return 1; }
	[ -n "$_qcd_n" ] || _qcd_n="${_qcd_p##*/}"
	_qcd_sz="$(wc -c <"$_qcd_p" 2>/dev/null)" || _qcd_sz=0
	if [ "${_qcd_sz:-0}" -gt "$QQBOT_FILE_DATA_MAX" ]; then
		_ERROR="qqbot.c2c.file: $_qcd_sz bytes > ${QQBOT_FILE_DATA_MAX} (file_data cap)"
		return 1
	fi
	_qcd_b="$(_qqbot_filedata_body "$_qcd_ty" "$_qcd_p" "$_qcd_n" "$_qcd_s")" || return 1
	_qcd_r="$(_qqbot_api_body "/v2/users/$(qqbot_seg "$1")/files" "$_qcd_b" "qqbot.c2c.file")" || {
		_qcd_rc=$?; rm -f "$_qcd_b"; return $_qcd_rc
	}
	rm -f "$_qcd_b"
	[ "$_qcd_s" = "true" ] && qqbot_track_sent c2c "$1" "$_qcd_r"
	printf '%s' "$_qcd_r"
}

# qqbot_send_group_file_typed <group_openid> <path> <file_type> <file_name> [content]
# Same as qqbot_send_group_file, but the caller supplies the media kind and the
# display name. Relayed media lands in an extension-less temp file, so
# qqbot_file_type_of would classify every picture as file_type=4 (plain file).
qqbot_send_group_file_typed() {
	_qsgft_resp="$(qqbot_file_upload_group_data "$1" "$3" "$2" "$4" false)" || return 1
	_qsgft_fi="$(json_get "$_qsgft_resp" file_info 2>/dev/null)" || _qsgft_fi=""
	case "$_qsgft_fi" in ''|NOTFOUND|null) _ERROR="qqbot.group.file: no file_info in response"; return 1 ;; esac
	qqbot_message_send_group_media "$1" "$_qsgft_fi" "${5:-}"
}

# qqbot_send_group_file_url <group_openid> <path> <file_type> <url> [content]
# Fallback for payloads above the 5MB file_data cap: upload by public URL.
qqbot_send_group_file_url() {
	_qsgfu_resp="$(qqbot_file_upload_group "$1" "$3" "$4" false)" || return 1
	_qsgfu_fi="$(json_get "$_qsgfu_resp" file_info 2>/dev/null)" || _qsgfu_fi=""
	case "$_qsgfu_fi" in ''|NOTFOUND|null) _ERROR="qqbot.group.file: no file_info in response"; return 1 ;; esac
	qqbot_message_send_group_media "$1" "$_qsgfu_fi" "${5:-}"
}

# qqbot_send_c2c_file_typed <user_openid> <path> <file_type> <file_name> [content]
qqbot_send_c2c_file_typed() {
	_qscft_resp="$(qqbot_file_upload_c2c_data "$1" "$3" "$2" "$4" false)" || return 1
	_qscft_fi="$(json_get "$_qscft_resp" file_info 2>/dev/null)" || _qscft_fi=""
	case "$_qscft_fi" in ''|NOTFOUND|null) _ERROR="qqbot.c2c.file: no file_info in response"; return 1 ;; esac
	qqbot_message_send_c2c_media "$1" "$_qscft_fi" "${5:-}"
}

# qqbot_send_c2c_file_url <user_openid> <path> <file_type> <url> [content]
qqbot_send_c2c_file_url() {
	_qscfu_resp="$(qqbot_file_upload_c2c "$1" "$3" "$4" false)" || return 1
	_qscfu_fi="$(json_get "$_qscfu_resp" file_info 2>/dev/null)" || _qscfu_fi=""
	case "$_qscfu_fi" in ''|NOTFOUND|null) _ERROR="qqbot.c2c.file: no file_info in response"; return 1 ;; esac
	qqbot_message_send_c2c_media "$1" "$_qscfu_fi" "${5:-}"
}

# qqbot_send_group_file <group_openid> <path> [content] [msg_id] [msg_seq]
# Upload then send as msg_type=7 media in one call — the usual "attach a file"
# path for handlers and sync.
qqbot_send_group_file() {
	_qsgf_resp="$(qqbot_file_upload_group_data "$1" "$(qqbot_file_type_of "$2")" "$2" "" false)" || return 1
	_qsgf_fi="$(json_get "$_qsgf_resp" file_info 2>/dev/null)" || _qsgf_fi=""
	case "$_qsgf_fi" in ''|NOTFOUND|null) _ERROR="qqbot.group.file: no file_info in response"; return 1 ;; esac
	qqbot_message_send_group_media "$1" "$_qsgf_fi" "${3:-}" "${4:-}" "${5:-}"
}

# qqbot_send_c2c_file <user_openid> <path> [content] [msg_id] [msg_seq]
qqbot_send_c2c_file() {
	_qscf_resp="$(qqbot_file_upload_c2c_data "$1" "$(qqbot_file_type_of "$2")" "$2" "" false)" || return 1
	_qscf_fi="$(json_get "$_qscf_resp" file_info 2>/dev/null)" || _qscf_fi=""
	case "$_qscf_fi" in ''|NOTFOUND|null) _ERROR="qqbot.c2c.file: no file_info in response"; return 1 ;; esac
	qqbot_message_send_c2c_media "$1" "$_qscf_fi" "${3:-}" "${4:-}" "${5:-}"
}
