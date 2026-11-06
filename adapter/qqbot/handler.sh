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

# qqbot_handler_recall — "/recall [n|all]" withdraws the bot's own recent
# replies in this conversation. The bot may only recall by id, and ids are not
# available from the platform afterwards, so we use the ids recorded by
# qqbot_track_sent (core.sh). Only the passive-reply window (5) is useful.
qqbot_handler_recall() {
	_qr_args="${4#/recall}"
	_qr_args="${_qr_args# }"
	case "$_qr_args" in
		""|1)   _qr_n=1 ;;
		all)    _qr_n="$QQBOT_SENT_KEEP" ;;
		*[!0-9]*) qqbot_reply_event "$5" "usage: /recall [1-$QQBOT_SENT_KEEP|all]"; return 0 ;;
		*)      _qr_n="$_qr_args" ;;
	esac
	[ "$_qr_n" -ge 1 ] 2>/dev/null || _qr_n=1
	[ "$_qr_n" -le "$QQBOT_SENT_KEEP" ] || _qr_n="$QQBOT_SENT_KEEP"

	_qr_d="$5"
	_qr_gid="$(json_get "$_qr_d" group_openid 2>/dev/null)" || _qr_gid=""
	_qr_ch="$(json_get "$_qr_d" channel_id 2>/dev/null)" || _qr_ch=""
	_qr_a="$(json_get "$_qr_d" author 2>/dev/null)" || _qr_a=""
	case "$_qr_gid" in NOTFOUND|null) _qr_gid="" ;; esac
	case "$_qr_ch" in NOTFOUND|null) _qr_ch="" ;; esac

	if [ -n "$_qr_gid" ]; then
		_qr_scene=group _qr_target="$_qr_gid"
	elif [ -n "$_qr_ch" ]; then
		_qr_scene=channel _qr_target="$_qr_ch"
	else
		_qr_scene=c2c
		_qr_target="$(json_get "$_qr_a" user_openid 2>/dev/null)" || _qr_target=""
		case "$_qr_target" in ''|NOTFOUND|null) _qr_target="$(json_get "$_qr_a" id 2>/dev/null)" ;; esac
	fi
	if [ -z "$_qr_target" ]; then
		_ERROR="qqbot.recall: no scene target"
		return 1
	fi

	_qr_ids="$(qqbot_sent_ids "$_qr_scene" "$_qr_target" "$_qr_n")"
	if [ -z "$_qr_ids" ]; then
		qqbot_reply_event "$_qr_d" "没有可撤回的消息" || return 1
		return 0
	fi

	_qr_ok=0 _qr_fail=0
	for _qr_id in $_qr_ids; do
		case "$_qr_scene" in
			group)   qqbot_message_recall_group "$_qr_target" "$_qr_id" ;;
			c2c)     qqbot_message_recall_c2c "$_qr_target" "$_qr_id" ;;
			channel) qqbot_message_recall_channel "$_qr_target" "$_qr_id" ;;
		esac
		if [ $? -eq 0 ]; then
			_qr_ok=$(( _qr_ok + 1 ))
			qqbot_sent_drop "$_qr_scene" "$_qr_target" "$_qr_id"
		else
			_qr_fail=$(( _qr_fail + 1 ))
			log_error "qqbot: recall $_qr_scene/$_qr_id failed: $_ERROR"
		fi
	done

	if [ "$_qr_fail" -gt 0 ]; then
		qqbot_reply_event "$_qr_d" "已撤回 $_qr_ok 条，$_qr_fail 条失败" || return 1
	else
		qqbot_reply_event "$_qr_d" "已撤回 $_qr_ok 条" || return 1
	fi
	log_info "qqbot: /recall $_qr_scene ok=$_qr_ok fail=$_qr_fail"
	return 0
}
