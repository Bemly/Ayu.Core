# test/test_qqbot_commands.sh — command level: what QQ actually receives
#
# test_qqbot_admin.sh stubs qqbot_reply_event, so a reply that never leaves the
# box still passes there. These tests drive the real path
# (admin → reply_event → message_send → _qqbot_api) and only fake the transport,
# asserting the request QQ would receive:
#
#   * 历史 in a full-stream group must go out as an active message (no msg_id):
#     QQ rejects a passive reply for GROUP_MESSAGE_CREATE, which is why the
#     command looked "ignored" while the handler returned success.
#   * 历史 on an @-event keeps the passive form with the event id.
#   * an empty log and a nickname bind still answer with their own text.

_QC_STATE="$(mktemp -d)"
_QC_OLD_STATE="$_STATE_DIR"
_QC_OLD_HIST="${QQBOT_HIST_DIR:-}"
_QC_OLD_NICK="${QQBOT_NICK_DIR:-}"
_QC_OLD_ADMINS="${QQBOT_ADMINS:-}"
_QC_OLD_BOT="${QQBOT_BOT_OPENID:-}"
_QC_OLD_MODE="${QQBOT_REPLY_MODE:-}"

_QC_ADMIN="9DB40F24307A212B6FE37AA4C0BD1A8E"
_QC_BOT="0048A836FFC38D84D2BD203330A85B26"
_QC_BODY="/tmp/qc-body-$$"
_QC_PATH="/tmp/qc-path-$$"

_qc_setup() {
	# test_qqbot_admin.sh replaces qqbot_reply_event with a recorder; reload the
	# real one so the transport below is genuinely exercised. handler.sh pulls
	# core.sh back in, which redefines _qqbot_api — fake it again afterwards.
	. ./adapter/qqbot/handler.sh
	_qqbot_api() {
		printf '%s\n' "$2" >> "$_QC_PATH"
		printf '%s' "$3" >> "$_QC_BODY"
		printf '{"id":"REPLYID"}\n'
		return 0
	}
	rm -rf "$_QC_STATE/qqbot-hist" "$_QC_STATE/qqbot-nick"
	mkdir -p "$_QC_STATE/qqbot-hist" "$_QC_STATE/qqbot-nick"
	_STATE_DIR="$_QC_STATE"
	QQBOT_HIST_DIR="$_QC_STATE/qqbot-hist"
	QQBOT_NICK_DIR="$_QC_STATE/qqbot-nick"
	QQBOT_ADMINS="$_QC_ADMIN"
	QQBOT_BOT_OPENID="$_QC_BOT"
	QQBOT_REPLY_MODE=""
	: > "$_QC_BODY"
	: > "$_QC_PATH"
}

_qc_body() { cat "$_QC_BODY" 2>/dev/null; }
_qc_paths() { cat "$_QC_PATH" 2>/dev/null; }

_qc_has() {
	case "$(_qc_body)" in *"$1"*) printf 'yes' ;; *) printf 'no' ;; esac
}

test_qqbot_cmd_history_full_stream_is_active() {
	_qc_setup
	qqbot_hist_append G1 MID1 "$_QC_ADMIN" "第一条记录"
	qqbot_admin_handle GROUP_MESSAGE_CREATE \
		"{\"id\":\"EVT1\",\"group_openid\":\"G1\",\"content\":\"\\u003c@$_QC_BOT\\u003e 历史\",\"author\":{\"member_openid\":\"$_QC_ADMIN\"}}" \
		G1 "$_QC_ADMIN"
	assert_ok "历史 in a full-stream group is consumed"
	assert_contains "$(_qc_body)" "最近 5 条" "history reply is actually sent"
	assert_contains "$(_qc_body)" "第一条记录" "history reply lists the stored line"
	assert_eq "$(_qc_has 'msg_id')" "no" "full-stream reply must be an active send (no msg_id)"

	_qc_unsetup
}

test_qqbot_cmd_history_at_event_is_passive() {
	_qc_setup
	qqbot_hist_append G1 MID1 "$_QC_ADMIN" "第一条记录"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"id\":\"EVT2\",\"group_openid\":\"G1\",\"content\":\"<@$_QC_BOT> 历史\"}" \
		G1 "$_QC_ADMIN"
	assert_ok "@-event 历史 is consumed"
	assert_contains "$(_qc_body)" "EVT2" "passive reply echoes the event id"
	assert_eq "$(_qc_has 'msg_seq')" "yes" "passive reply carries msg_seq"

	_qc_unsetup
}

test_qqbot_cmd_history_empty() {
	_qc_setup
	qqbot_admin_handle GROUP_MESSAGE_CREATE \
		"{\"id\":\"EVT3\",\"group_openid\":\"G1\",\"content\":\"\\u003c@$_QC_BOT\\u003e 历史\"}" \
		G1 "$_QC_ADMIN"
	assert_ok "历史 with an empty log is consumed"
	assert_contains "$(_qc_body)" "还没有记录" "empty log answered"

	_qc_unsetup
}

test_qqbot_cmd_bind_reply_reaches_send() {
	_qc_setup
	qqbot_admin_handle GROUP_MESSAGE_CREATE \
		"{\"id\":\"EVT4\",\"group_openid\":\"G1\",\"content\":\"\\u003c@$_QC_BOT\\u003e \\u003c@ABC1234D9F19B085571787A9E0F3C0B6\\u003e 宝宝\"}" \
		G1 "$_QC_ADMIN"
	assert_ok "bind in a full-stream group is consumed"
	assert_eq "$(qqbot_nick_get G1 ABC1234D9F19B085571787A9E0F3C0B6)" "宝宝" "binding stored"
	assert_contains "$(_qc_body)" "已绑定" "bind confirmation is actually sent"
	assert_contains "$(_qc_paths)" "/v2/groups/G1/messages" "reply goes to the group endpoint"

	_qc_unsetup
}

_qc_unsetup() {
	_STATE_DIR="$_QC_OLD_STATE"
	QQBOT_HIST_DIR="$_QC_OLD_HIST"
	QQBOT_NICK_DIR="$_QC_OLD_NICK"
	QQBOT_ADMINS="$_QC_OLD_ADMINS"
	QQBOT_BOT_OPENID="$_QC_OLD_BOT"
	QQBOT_REPLY_MODE="$_QC_OLD_MODE"
	: > "$_QC_BODY"
	: > "$_QC_PATH"
}

test_qqbot_cmd_history_full_stream_is_active
test_qqbot_cmd_history_at_event_is_passive
test_qqbot_cmd_history_empty
test_qqbot_cmd_bind_reply_reaches_send

rm -f "$_QC_BODY" "$_QC_PATH"
test_purge "$_QC_STATE"
