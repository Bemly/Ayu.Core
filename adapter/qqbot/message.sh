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

qqbot_message_send_group()      { _qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/messages" "$(qqbot_body_text "$2" "${3:-}" "${4:-}")" "qqbot.group.send"; }
qqbot_message_send_group_raw()  { _qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/messages" "$2" "qqbot.group.send"; }
qqbot_message_send_group_md()   { _qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/messages" "$(qqbot_body_markdown "$2" "${3:-}" "${4:-}")" "qqbot.group.send_md"; }
qqbot_message_recall_group()    { _qqbot_api DELETE "/v2/groups/$(qqbot_seg "$1")/messages/$(qqbot_seg "$2")" "{}" "qqbot.group.recall" >/dev/null; }

# ---- c2c (single chat) --------------------------------------------------

qqbot_message_send_c2c()        { _qqbot_api POST "/v2/users/$(qqbot_seg "$1")/messages" "$(qqbot_body_text "$2" "${3:-}" "${4:-}")" "qqbot.c2c.send"; }
qqbot_message_send_c2c_raw()    { _qqbot_api POST "/v2/users/$(qqbot_seg "$1")/messages" "$2" "qqbot.c2c.send"; }
qqbot_message_send_c2c_md()     { _qqbot_api POST "/v2/users/$(qqbot_seg "$1")/messages" "$(qqbot_body_markdown "$2" "${3:-}" "${4:-}")" "qqbot.c2c.send_md"; }
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
