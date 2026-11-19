# adapter/qqbot/message.sh — QQ Bot message / media APIs
#
# Endpoints (OpenAPI v2):
#   POST   /v2/groups/{group_openid}/messages
#   POST   /v2/users/{user_openid}/messages
#   POST   /v2/users/{user_openid}/stream_messages
#   DELETE /v2/groups/{group_openid}/messages/{message_id}
#   DELETE /v2/users/{user_openid}/messages/{message_id}
#   POST   /channels/{channel_id}/messages
#   POST   /v2/groups/{group_openid}/files        (URL / file_data / upload_id)
#   POST   /v2/users/{user_openid}/files
#
# 消息体字段全集（v2_groups_group_openid_messages.post）:
#   msg_type           0=text 2=markdown 7=media 8=ark(card)
#   content            text 正文 / media 封面文字
#   markdown           {content, custom_template_id, params[{key,values[]}],
#                       force_verify_image_resource}
#   keyboard           {id} 或 {content:{rows[[{id,render_data{label,visited_label,style},
#                       action{type,permission{type,specify_role_ids,specify_user_ids},
#                       data,unsupport_tips,enter,reply,anchor,click_limit}}]]}}
#   card               {type:"tuwen", content:...}（图文卡片，msg_type=8）
#   media              {file_info}
#   message_reference  {message_id, ignore_get_message_error}
#   msg_id             被动回复：事件 d.id（5 分钟窗口，最多 4-5 条）
#   event_id           被动回复：事件 id，与 msg_id 二选一，建议带
#   msg_seq            同一 msg_id 的序号，必须递增，重复即被拒
#
# Passive replies must echo msg_id (5 min window, max 4-5 replies per msg_id)
# and use an incrementing msg_seq; the platform rejects repeated msg_id+msg_seq.

[ "${_QQBOT_MESSAGE_SH:-0}" = "1" ] && return 0
_QQBOT_MESSAGE_SH=1

. "$_HB/adapter/qqbot/core.sh"
. "$_HB/adapter/qqbot/richtext.sh"

# ---- body builders (legacy signatures kept) -----------------------------

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

# qqbot_body_keyboard <keyboard_json> — inline keyboard object, verbatim
qqbot_body_keyboard() { json_obj keyboard "$1"; }

# qqbot_body_card <card_json> — 图文卡片, msg_type=8
qqbot_body_card() { json_obj msg_type 8 card "$1"; }

# ---- message option parser ---------------------------------------------
# One option carrier for both scenes; hush has no local, so the names are
# MSG_* and every entry point resets them first.

qqbot_msg_opts_reset() {
	MSG_TEXT="" MSG_MD="" MSG_MD_INLINE="" MSG_TEMPLATE="" MSG_PARAMS="" MSG_VERIFY_IMG=""
	MSG_KEYBOARD="" MSG_KEYBOARD_JSON="" MSG_KEYBOARD_ROWS="" MSG_CARD="" MSG_ARK="" MSG_MEDIA="" MSG_MSG_ID="" MSG_EVENT_ID=""
	MSG_MSG_SEQ="" MSG_REF="" MSG_IGNORE_REF="" MSG_ERR=""
	return 0
}

# qqbot_msg_opts <args...> — parse CLI-style flags:
#   --text T | --md | (bare word = text/markdown body)
#   --md-inline          markdown 时是否声明原生 markdown（默认 1）
#   --template ID        markdown 模板 id（自定义模板时必须）
#   --params JSON        markdown 模板参数 [{"key":"k","values":["v"]}]
#   --verify-img 0|1     markdown.force_verify_image_resource
#   --keyboard ID        keyboard.id（平台模板键盘）
#   --keyboard-rows J    keyboard.content.rows 数组（[{"buttons":[...]}]）
#   --keyboard-json J    完整 keyboard 对象原样透传（与 id/rows 互斥，优先级最高）
#   --card JSON          图文卡片 card 对象
#   --media FILE_INFO    media.file_info（先上传后拿到）
#   --msg-id ID          被动回复 msg_id
#   --event-id ID        被动回复 event_id
#   --msg-seq N          被动回复序号
#   --reply MSG_ID       引用回复 message_reference.message_id
#   --ignore-ref         message_reference.ignore_get_message_error=true
qqbot_msg_opts() {
	_qqo_first=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--text)          MSG_TEXT="$2"; shift 2 ;;
			--md)            MSG_MD=1; shift ;;
			--md-inline)     MSG_MD_INLINE="$2"; shift 2 ;;
			--template)      MSG_TEMPLATE="$2"; MSG_MD=1; shift 2 ;;
			--params)        MSG_PARAMS="$2"; shift 2 ;;
			--verify-img)    MSG_VERIFY_IMG="$2"; shift 2 ;;
			--keyboard)      MSG_KEYBOARD="$2"; shift 2 ;;
			--keyboard-json) MSG_KEYBOARD_JSON="$2"; shift 2 ;;
			--keyboard-rows) MSG_KEYBOARD_ROWS="$2"; shift 2 ;;
			--card)          MSG_CARD="$2"; shift 2 ;;
			--ark)           MSG_ARK="$2"; shift 2 ;;
			--media)         MSG_MEDIA="$2"; shift 2 ;;
			--msg-id)        MSG_MSG_ID="$2"; shift 2 ;;
			--event-id)      MSG_EVENT_ID="$2"; shift 2 ;;
			--msg-seq)       MSG_MSG_SEQ="$2"; shift 2 ;;
			--reply)         MSG_REF="$2"; shift 2 ;;
			--ignore-ref)    MSG_IGNORE_REF="true"; shift ;;
			--) shift; break ;;
			-*)  MSG_ERR="unknown option $1"; return 1 ;;
			*)   if [ -z "$_qqo_first" ]; then _qqo_first="$1"; else
				MSG_ERR="unexpected argument $1"; return 1
			     fi
			     shift ;;
		esac
	done
	[ -n "$MSG_TEXT" ] || MSG_TEXT="$_qqo_first"
	return 0
}

# qqbot_msg_body → request body for the current MSG_* set
# msg_type precedence: card(8) > media(7) > ark(3) > markdown(2) > text(0)
qqbot_msg_body() {
	_qmb_parts=""
	_qmb_ty=0

	if [ -n "$MSG_CARD" ]; then
		_qmb_ty=8
		_qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"card\":$MSG_CARD")"
	elif [ -n "$MSG_MEDIA" ]; then
		_qmb_ty=7
		_qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"media\":{\"file_info\":$(json_escape "$MSG_MEDIA")}")"
	elif [ -n "$MSG_ARK" ]; then
		_qmb_ty=3
		_qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"ark\":$MSG_ARK")"
	elif [ -n "$MSG_MD" ] || [ -n "$MSG_TEMPLATE" ]; then
		_qmb_ty=2
		_qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"markdown\":$(_qqbot_md_obj)")"
	fi
	_qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"msg_type\":$_qmb_ty")"

	# 官方约束：传了 markdown 后 content 必须为空（否则 22006 消息类型与内容不匹配）；
	# 图文卡片同理只认 card。富媒体(msg_type=7) 允许 content 作为附带文字。
	case "$_qmb_ty" in
		0|7) [ -n "$MSG_TEXT" ] && _qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"content\":$(json_escape "$MSG_TEXT")")" ;;
		2|3|8) : ;;
	esac

	if [ -n "$MSG_KEYBOARD_JSON" ]; then
		_qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"keyboard\":$MSG_KEYBOARD_JSON")"
	elif [ -n "$MSG_KEYBOARD_ROWS" ]; then
		_qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"keyboard\":{\"content\":{\"rows\":$MSG_KEYBOARD_ROWS}}")"
	elif [ -n "$MSG_KEYBOARD" ]; then
		_qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"keyboard\":{\"id\":$(json_escape "$MSG_KEYBOARD")}")"
	fi

	if [ -n "$MSG_MSG_ID" ] || [ -n "$MSG_EVENT_ID" ] || [ -n "$MSG_MSG_SEQ" ]; then
		[ -n "$MSG_MSG_ID" ] && _qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"msg_id\":$(json_escape "$MSG_MSG_ID")")"
		[ -n "$MSG_EVENT_ID" ] && _qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"event_id\":$(json_escape "$MSG_EVENT_ID")")"
		[ -n "$MSG_MSG_SEQ" ] && _qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"msg_seq\":$MSG_MSG_SEQ")"
	fi

	if [ -n "$MSG_REF" ]; then
		_qmb_ref="\"message_id\":$(json_escape "$MSG_REF")"
		[ -n "$MSG_IGNORE_REF" ] && _qmb_ref="$_qmb_ref,\"ignore_get_message_error\":true"
		_qmb_parts="$(_qqbot_joinit "$_qmb_parts" "\"message_reference\":{$_qmb_ref}")"
	fi

	printf '{%s}' "$_qmb_parts"
}

# _qqbot_md_obj — markdown object for the current MSG_* set
# force_verify_image_resource only means something for native markdown
# (msg_type=2 且未用模板); a template ignores it.
_qqbot_md_obj() {
	_qmo="\"content\":$(json_escape "$MSG_TEXT")"
	[ -n "$MSG_TEMPLATE" ] && _qmo="$_qmo,\"custom_template_id\":$(json_escape "$MSG_TEMPLATE")"
	[ -n "$MSG_PARAMS" ] && _qmo="$_qmo,\"params\":$MSG_PARAMS"
	if [ -z "$MSG_TEMPLATE" ]; then
		case "${MSG_VERIFY_IMG:-1}" in
			0|false) _qmo="$_qmo,\"force_verify_image_resource\":false" ;;
			*)       _qmo="$_qmo,\"force_verify_image_resource\":true" ;;
		esac
	fi
	printf '{%s}' "$_qmo"
}

# ---- send: option-driven, both scenes ----------------------------------

# qqbot_msg_send <group|c2c> <openid> [--track] <opts...>
# Prints the API response. --track records the returned id for /recall.
qqbot_msg_send() {
	_qms_scene="$1" _qms_id="$2"; shift 2
	_qms_track=0
	[ "${1:-}" = "--track" ] && { _qms_track=1; shift; }
	qqbot_msg_opts_reset
	qqbot_msg_opts "$@" || { _ERROR="qqbot.$_qms_scene.send: $MSG_ERR"; return 1; }
	_qms_body="$(qqbot_msg_body)"
	if [ "$_qms_scene" = "group" ]; then
		_qms_r="$(_qqbot_api POST "/v2/groups/$(qqbot_seg "$_qms_id")/messages" "$_qms_body" "qqbot.group.send")" || return 1
	else
		_qms_r="$(_qqbot_api POST "/v2/users/$(qqbot_seg "$_qms_id")/messages" "$_qms_body" "qqbot.c2c.send")" || return 1
	fi
	[ "$_qms_track" = "1" ] && qqbot_track_sent "$_qms_scene" "$_qms_id" "$_qms_r"
	printf '%s' "$_qms_r"
}

# ---- convenience senders (legacy + new) --------------------------------

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

# qqbot_send_group_md <group_openid> <markdown> [msg_id] [msg_seq]
qqbot_send_group_md() { qqbot_message_send_group_md "$@"; }

# qqbot_send_group_keyboard <group_openid> <keyboard_id> <text>
qqbot_send_group_keyboard() {
	qqbot_msg_send group "$1" --track --keyboard "$2" --text "$3"
}

# qqbot_send_group_card <group_openid> <card_json> [content]
qqbot_send_group_card() {
	qqbot_msg_send group "$1" --track --card "$2" --text "${3:-}"
}
qqbot_send_c2c_card() {
	qqbot_msg_send c2c "$1" --track --card "$2" --text "${3:-}"
}

# qqbot_send_group_md_template <group_openid> <template_id> <params_json> [content]
qqbot_send_group_md_template() {
	qqbot_msg_send group "$1" --track --template "$2" --params "$3" --text "${4:-}"
}

# qqbot_send_group_reply <group_openid> <content> <msg_id> [event_id] [msg_seq]
# 被动回复 + 引用原消息；content 可以是 markdown（--md 由调用方决定）
qqbot_send_group_reply() {
	qqbot_msg_send group "$1" --track --text "$2" --msg-id "$3" --event-id "${4:-}" \
		--msg-seq "${5:-1}" --reply "$3"
}

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

qqbot_send_c2c_md() { qqbot_message_send_c2c_md "$@"; }

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

# ---- rich media: /files -------------------------------------------------

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

# qqbot_file_upload_group_uid <group_openid> <file_type> <upload_id> [file_name] [srv_send_msg]
# 行 3 步合并：分片传完后用 upload_id 换 file_info
qqbot_file_upload_group_uid() {
	_qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/files" \
		"$(json_obj file_type "$2" file_name "${4:-}" upload_id "$3" srv_send_msg "${5:-false}")" "qqbot.group.file"
}

qqbot_file_upload_c2c_uid() {
	_qqbot_api POST "/v2/users/$(qqbot_seg "$1")/files" \
		"$(json_obj file_type "$2" file_name "${4:-}" upload_id "$3" srv_send_msg "${5:-false}")" "qqbot.c2c.file"
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
# The platform takes binary media either as a public URL, as a base64
# `file_data` field capped at 5MB, or through the chunked flow in upload.sh.
# Keeping the <=5MB path a plain base64 body means no extra dependency:
# /bin/base64 is a busybox applet.

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

# qqbot_upload_any <scene> <openid> <path> <file_type> <file_name>
# 统一上传入口：≤5MB 走 file_data；>5MB 走 upload.sh 的分片流。
# 只在分组/单聊两侧的 /files 路径上分叉，调用方拿到的是同一个
# {file_info, file_uuid, ttl, id, raw_url} 形状。
qqbot_upload_any() {
	_qua_scene="$1" _qua_id="$2" _qua_p="$3" _qua_ty="$4" _qua_n="$5"
	[ -f "$_qua_p" ] || { _ERROR="qqbot.upload: no such file $_qua_p"; return 1; }
	[ -n "$_qua_n" ] || _qua_n="${_qua_p##*/}"
	_qua_sz="$(_qqbot_file_size "$_qua_p")"
	if [ "${_qua_sz:-0}" -le "$QQBOT_FILE_DATA_MAX" ]; then
		if [ "$_qua_scene" = "group" ]; then
			qqbot_file_upload_group_data "$_qua_id" "$_qua_ty" "$_qua_p" "$_qua_n" false
		else
			qqbot_file_upload_c2c_data "$_qua_id" "$_qua_ty" "$_qua_p" "$_qua_n" false
		fi
		return $?
	fi
	. "$_HB/adapter/qqbot/upload.sh"
	qqbot_upload_file "$_qua_scene" "$_qua_id" "$_qua_p" "$_qua_ty" "$_qua_n" false
}

# qqbot_send_group_file_typed <group_openid> <path> <file_type> <file_name> [content]
# Same as qqbot_send_group_file, but the caller supplies the media kind and the
# display name. Relayed media lands in an extension-less temp file, so
# qqbot_file_type_of would classify every picture as file_type=4 (plain file).
qqbot_send_group_file_typed() {
	_qsgft_resp="$(qqbot_upload_any group "$1" "$2" "$3" "$4")" || return 1
	_qsgft_fi="$(json_get "$_qsgft_resp" file_info 2>/dev/null)" || _qsgft_fi=""
	case "$_qsgft_fi" in ''|NOTFOUND|null)
		_ERROR="qqbot.group.file: no file_info in response body=$(_qqbot_resp_digest "$_qsgft_resp")"
		_qqbot_note_err "$_ERROR"; return 1 ;;
	esac
	qqbot_message_send_group_media "$1" "$_qsgft_fi" "${5:-}"
}

# qqbot_send_group_file_url <group_openid> <path> <file_type> <url> [content]
# Fallback when the payload cannot be uploaded by value at all.
qqbot_send_group_file_url() {
	_qsgfu_resp="$(qqbot_file_upload_group "$1" "$3" "$4" false)" || return 1
	_qsgfu_fi="$(json_get "$_qsgfu_resp" file_info 2>/dev/null)" || _qsgfu_fi=""
	case "$_qsgfu_fi" in ''|NOTFOUND|null)
		_ERROR="qqbot.group.file: no file_info in response body=$(_qqbot_resp_digest "$_qsgfu_resp")"
		_qqbot_note_err "$_ERROR"; return 1 ;;
	esac
	qqbot_message_send_group_media "$1" "$_qsgfu_fi" "${5:-}"
}

# qqbot_send_c2c_file_typed <user_openid> <path> <file_type> <file_name> [content]
qqbot_send_c2c_file_typed() {
	_qscft_resp="$(qqbot_upload_any c2c "$1" "$2" "$3" "$4")" || return 1
	_qscft_fi="$(json_get "$_qscft_resp" file_info 2>/dev/null)" || _qscft_fi=""
	case "$_qscft_fi" in ''|NOTFOUND|null)
		_ERROR="qqbot.c2c.file: no file_info in response body=$(_qqbot_resp_digest "$_qscft_resp")"
		_qqbot_note_err "$_ERROR"; return 1 ;;
	esac
	qqbot_message_send_c2c_media "$1" "$_qscft_fi" "${5:-}"
}

# qqbot_send_c2c_file_url <user_openid> <path> <file_type> <url> [content]
qqbot_send_c2c_file_url() {
	_qscfu_resp="$(qqbot_file_upload_c2c "$1" "$3" "$4" false)" || return 1
	_qscfu_fi="$(json_get "$_qscfu_resp" file_info 2>/dev/null)" || _qscfu_fi=""
	case "$_qscfu_fi" in ''|NOTFOUND|null)
		_ERROR="qqbot.c2c.file: no file_info in response body=$(_qqbot_resp_digest "$_qscfu_resp")"
		_qqbot_note_err "$_ERROR"; return 1 ;;
	esac
	qqbot_message_send_c2c_media "$1" "$_qscfu_fi" "${5:-}"
}

# qqbot_send_group_file <group_openid> <path> [content] [msg_id] [msg_seq]
# Upload then send as msg_type=7 media in one call — the usual "attach a file"
# path for handlers and sync.
qqbot_send_group_file() {
	_qsgf_resp="$(qqbot_upload_any group "$1" "$2" "$(qqbot_file_type_of "$2")" "")" || return 1
	_qsgf_fi="$(json_get "$_qsgf_resp" file_info 2>/dev/null)" || _qsgf_fi=""
	case "$_qsgf_fi" in ''|NOTFOUND|null)
		_ERROR="qqbot.group.file: no file_info in response body=$(_qqbot_resp_digest "$_qsgf_resp")"
		_qqbot_note_err "$_ERROR"; return 1 ;;
	esac
	qqbot_message_send_group_media "$1" "$_qsgf_fi" "${3:-}" "${4:-}" "${5:-}"
}

# qqbot_send_c2c_file <user_openid> <path> [content] [msg_id] [msg_seq]
qqbot_send_c2c_file() {
	_qscf_resp="$(qqbot_upload_any c2c "$1" "$2" "$(qqbot_file_type_of "$2")" "")" || return 1
	_qscf_fi="$(json_get "$_qscf_resp" file_info 2>/dev/null)" || _qscf_fi=""
	case "$_qscf_fi" in ''|NOTFOUND|null)
		_ERROR="qqbot.c2c.file: no file_info in response body=$(_qqbot_resp_digest "$_qscf_resp")"
		_qqbot_note_err "$_ERROR"; return 1 ;;
	esac
	qqbot_message_send_c2c_media "$1" "$_qscf_fi" "${3:-}" "${4:-}" "${5:-}"
}
