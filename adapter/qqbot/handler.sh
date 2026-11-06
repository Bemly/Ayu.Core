# adapter/qqbot/handler.sh — built-in commands for QQ Bot
#
# Handler signature matches dispatch(): <platform> <event> <uid> <text> <raw>
# <raw> is the event's `d` object, which carries the ids needed to reply:
#   group  → group_openid + id
#   c2c    → author.user_openid + id
#   guild  → channel_id + id

. "$_HB/adapter/qqbot/message.sh"

# qqbot_reply_event <raw d> <text> — reply in the same scene the event came from
qqbot_reply_event() {
	_qp_d="$1" _qp_text="$2"
	_qp_gid="$(json_get "$_qp_d" group_openid 2>/dev/null)" || _qp_gid=""
	_qp_mid="$(json_get "$_qp_d" id 2>/dev/null)" || _qp_mid=""
	_qp_ch="$(json_get "$_qp_d" channel_id 2>/dev/null)" || _qp_ch=""
	_qp_a="$(json_get "$_qp_d" author 2>/dev/null)" || _qp_a=""

	if [ -n "$_qp_gid" ]; then
		qqbot_message_send_group "$_qp_gid" "$_qp_text" "$_qp_mid" 1
		return $?
	fi
	if [ -n "$_qp_ch" ]; then
		qqbot_message_send_channel "$_qp_ch" "$_qp_text" "$_qp_mid" 1
		return $?
	fi
	_qp_uid="$(json_get "$_qp_a" user_openid 2>/dev/null)" || _qp_uid=""
	[ -n "$_qp_uid" ] || _qp_uid="$(json_get "$_qp_a" id 2>/dev/null)"
	if [ -n "$_qp_uid" ]; then
		qqbot_message_send_c2c "$_qp_uid" "$_qp_text" "$_qp_mid" 1
		return $?
	fi
	_ERROR="qqbot.handler: no reply target in event"
	return 1
}

qqbot_handler_ping() {
	qqbot_reply_event "$5" "pong" || return 1
	log_info "qqbot: /ping answered"
	return 0
}

qqbot_handler_echo() {
	# text is "/echo ..." — strip the command word
	_qe_args="${4#/echo}"
	_qe_args="${_qe_args# }"
	[ -n "$_qe_args" ] || _qe_args="(empty)"
	qqbot_reply_event "$5" "$_qe_args" || return 1
	return 0
}

qqbot_handler_info() {
	_qi_env="${AYU_ENV:-dev}"
	_qi_sig="off"
	qqbot_signature_enabled && _qi_sig="on"
	_qi_txt="Ayu.Core qqbot
env: $_qi_env
appid: ${QQBOT_APP_ID:-(unset)}
api: $QQBOT_API_BASE
sig-verify: $_qi_sig"
	qqbot_reply_event "$5" "$_qi_txt" || return 1
	return 0
}
