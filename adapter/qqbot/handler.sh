# adapter/qqbot/handler.sh — built-in commands for QQ Bot
#
# Handler signature matches dispatch(): <platform> <event> <uid> <text> <raw>
# <raw> is the event's `d` object, which carries the ids needed to reply:
#   group  → group_openid + id
#   c2c    → author.user_openid + id
#   guild  → channel_id + id
#
# 被动回复字段（官方 v2_groups_group_openid_messages.post）：
#   msg_id    事件 d.id，5 分钟内有效，同一 msg_id 最多回 4-5 条
#   event_id  事件 id（可选，建议带；与 msg_id 同时出现时平台优先 msg_id）
#   msg_seq   同一 msg_id 的序号，必须递增，重复即被拒
# 出站形态由 QQBOT_REPLY_MODE 控制：md（默认，msg_type=2）| text（msg_type=0）。
# markdown 发送失败时自动降级为 text 再试一次，避免"机器人不吭声"。

. "$_HB/adapter/qqbot/message.sh"

QQBOT_REPLY_MODE="${QQBOT_REPLY_MODE:-md}"   # md | text
QQBOT_REPLY_QUOTE="${QQBOT_REPLY_QUOTE:-0}"  # 1 → message_reference 引用原消息
QQBOT_MSG_SEQ_N="${QQBOT_MSG_SEQ_N:-0}"

# _qqbot_event_target <d> → sets _ET_SCENE (group|channel|c2c) and _ET_ID
_qqbot_event_target() {
	_et_g="$(json_get "$1" group_openid 2>/dev/null)" || _et_g=""
	_et_c="$(json_get "$1" channel_id 2>/dev/null)" || _et_c=""
	_et_a="$(json_get "$1" author 2>/dev/null)" || _et_a=""
	case "$_et_g" in NOTFOUND|null) _et_g="" ;; esac
	case "$_et_c" in NOTFOUND|null) _et_c="" ;; esac
	if [ -n "$_et_g" ]; then
		_ET_SCENE=group _ET_ID="$_et_g"
	elif [ -n "$_et_c" ]; then
		_ET_SCENE=channel _ET_ID="$_et_c"
	else
		_ET_SCENE=c2c
		_ET_ID="$(json_get "$_et_a" user_openid 2>/dev/null)" || _ET_ID=""
		case "$_ET_ID" in ''|NOTFOUND|null) _ET_ID="$(json_get "$_et_a" id 2>/dev/null)" ;; esac
		case "$_ET_ID" in NOTFOUND|null) _ET_ID="" ;; esac
	fi
	return 0
}

# qqbot_msg_seq_next → incrementing msg_seq for this process
qqbot_msg_seq_next() {
	QQBOT_MSG_SEQ_N=$(( QQBOT_MSG_SEQ_N + 1 ))
	[ "$QQBOT_MSG_SEQ_N" -le 1 ] && QQBOT_MSG_SEQ_N=1
	printf '%s' "$QQBOT_MSG_SEQ_N"
}

# qqbot_reply_event_opts <raw d> <passive|active> <msg.sh opts...>
# One reply path for every scene. Passive mode injects msg_id + event_id +
# msg_seq; active mode drops them (a full-stream GROUP_MESSAGE_CREATE cannot
# be answered passively, QQ rejects it without an HTTP error).
qqbot_reply_event_opts() {
	_qro_d="$1" _qro_mode="$2"; shift 2
	_qqbot_event_target "$_qro_d"
	if [ -z "$_ET_ID" ]; then
		_ERROR="qqbot.handler: no reply target in event"
		return 1
	fi
	# Passive fields are appended as positional parameters, never as a string
	# expanded unquoted: hush does not split `$var` reliably when the variable
	# holds several options, which sent "--msg-id M1 --msg-seq 1" as one lone
	# argument and made every passive reply fail with "unknown option".
	set -- "$@"
	if [ "$_qro_mode" != "active" ]; then
		_qro_mid="$(json_get "$_qro_d" id 2>/dev/null)" || _qro_mid=""
		case "$_qro_mid" in ''|NOTFOUND|null) _qro_mid="" ;; esac
		_qro_ev="$(json_get "$_qro_d" event_id 2>/dev/null)" || _qro_ev=""
		case "$_qro_ev" in NOTFOUND|null) _qro_ev="" ;; esac
		if [ -n "$_qro_mid" ]; then
			set -- --msg-id "$_qro_mid" --msg-seq "$(qqbot_msg_seq_next)" "$@"
			[ -n "$_qro_ev" ] && set -- --event-id "$_qro_ev" "$@"
			[ "$QQBOT_REPLY_QUOTE" = "1" ] && set -- --reply "$_qro_mid" "$@"
		fi
	fi
	[ -n "${QQBOT_REPLY_KEYBOARD:-}" ] && set -- --keyboard "$QQBOT_REPLY_KEYBOARD" "$@"

	# The send helpers run inside $(...) so the parent _ERROR never sees their
	# failure reason. Route the detail through QQBOT_ERR_FILE, otherwise the
	# log only ever shows "send failed ()" — which hid a body-level rejection
	# (QQ 50015001) for a whole debugging session.
	_qro_ef="${QQBOT_ERR_FILE:-}"
	_qro_efile="/tmp/qqbot-reply.$$"; : >"$_qro_efile"; QQBOT_ERR_FILE="$_qro_efile"

	if qqbot_msg_send "$_ET_SCENE" "$_ET_ID" --track "$@" >/dev/null 2>&1; then
		_qqbot_reply_release
		return 0
	fi
	_ERROR="qqbot.reply: $_ET_SCENE ($_qro_mode) send failed ($(_qqbot_reply_why))"
	_qqbot_reply_release
	log_err "$_ERROR"
	return 1
}

# qqbot_reply_event <raw d> <text> [passive|active]
qqbot_reply_event() {
	_qre_d="$1" _qre_text="$2" _qre_mode="${3:-passive}"
	if [ "$QQBOT_REPLY_MODE" = "md" ]; then
		if qqbot_reply_event_opts "$_qre_d" "$_qre_mode" --md --text "$_qre_text"; then
			return 0
		fi
		# markdown 被拒（未开通 / 模板校验失败）时退回纯文本，只回退一次
		log_debug "qqbot: markdown reply failed, falling back to text"
	fi
	qqbot_reply_event_opts "$_qre_d" "$_qre_mode" --text "$_qre_text"
}

# _qqbot_reply_why — last detail recorded by the send helper, one line
_qqbot_reply_why() {
	_w="$(tail -n 1 "${_qro_efile:-/dev/null}" 2>/dev/null)"
	[ -n "$_w" ] || _w="no detail"
	printf '%s' "$_w"
}

# _qqbot_reply_release — drop the temp file and restore the caller's variable
_qqbot_reply_release() {
	rm -f "${_qro_efile:-/dev/null}" 2>/dev/null
	if [ -n "${_qro_ef:-}" ]; then
		QQBOT_ERR_FILE="$_qro_ef"
	else
		unset QQBOT_ERR_FILE
	fi
	return 0
}

# qqbot_reply_media <raw d> <path> [file_type] [file_name] [content]
# 被动窗口内直接发附件：先上传（≤5MB file_data / >5MB 分片），再 media 消息。
qqbot_reply_media() {
	_qrm_d="$1" _qrm_p="$2" _qrm_ty="${3:-}" _qrm_n="${4:-}" _qrm_txt="${5:-}"
	_qqbot_event_target "$_qrm_d"
	[ -n "$_ET_ID" ] || { _ERROR="qqbot.handler: no reply target in event"; return 1; }
	[ -n "$_qrm_ty" ] || _qrm_ty="$(qqbot_file_type_of "$_qrm_p")"
	_qrm_mode=passive
	_qrm_mid="$(json_get "$_qrm_d" id 2>/dev/null)" || _qrm_mid=""
	case "$_qrm_mid" in ''|NOTFOUND|null) _qrm_mid="" ;; esac
	[ -n "$_qrm_mid" ] || _qrm_mode=active

	if [ "$_ET_SCENE" = "group" ]; then
		if [ -n "$_qrm_mid" ]; then
			qqbot_send_group_file_typed "$_ET_ID" "$_qrm_p" "$_qrm_ty" "$_qrm_n" "$_qrm_txt"
		else
			qqbot_send_group_file_typed "$_ET_ID" "$_qrm_p" "$_qrm_ty" "$_qrm_n" "$_qrm_txt"
		fi
	else
		qqbot_send_c2c_file_typed "$_ET_ID" "$_qrm_p" "$_qrm_ty" "$_qrm_n" "$_qrm_txt"
	fi
}

# qqbot_reply_card <raw d> <card_json> [content]
qqbot_reply_card() {
	_qqbot_event_target "$1"
	[ -n "$_ET_ID" ] || { _ERROR="qqbot.handler: no reply target in event"; return 1; }
	qqbot_msg_send "$_ET_SCENE" "$_ET_ID" --track --card "$2" --text "${3:-}"
}

# qqbot_reply_keyboard <raw d> <keyboard_id> <content>
qqbot_reply_keyboard() {
	_qqbot_event_target "$1"
	[ -n "$_ET_ID" ] || { _ERROR="qqbot.handler: no reply target in event"; return 1; }
	qqbot_msg_send "$_ET_SCENE" "$_ET_ID" --track --keyboard "$2" --text "$3"
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
	_qqbot_event_target "$_qr_d"
	_qr_scene="$_ET_SCENE" _qr_target="$_ET_ID"
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
