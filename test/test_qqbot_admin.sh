# test/test_qqbot_admin.sh — group commands: nickname bind / history
#
# The official API exposes no nickname, so an admin binds one to an openid.
# These tests cover the permission gate, both target forms (mention / 7-char
# prefix), unlimited rewrites, the relay sender, and the message log.

_QA_STATE="$(mktemp -d)"
_QA_OLD_STATE="$_STATE_DIR"
_STATE_DIR="$_QA_STATE"
_HB_TMP_ADMIN="${QQBOT_ADMINS:-}"

. ./plugin/sync/common.sh

_QA_ADMIN="9DB40F24307A212B6FE37AA4C0BD1A8E"
_QA_P="ABC1234D9F19B085571787A9E0F3C0B6"

# capture the reply instead of calling the API
_qa_setup() {
	_QA_REPLY=""
	mkdir -p "$_QA_STATE"
	rm -rf "$_QA_STATE/qqbot-nick" "$_QA_STATE/qqbot-hist"
	QQBOT_NICK_DIR="$_QA_STATE/qqbot-nick"
	QQBOT_HIST_DIR="$_QA_STATE/qqbot-hist"
	QQBOT_ADMINS="$_QA_ADMIN"
	qqbot_reply_event() { _QA_REPLY="$2"; }
}
_qa_unsetup() {
	QQBOT_NICK_DIR="${_QA_STATE}/qqbot-nick"
	QQBOT_HIST_DIR="${_QA_STATE}/qqbot-hist"
	QQBOT_ADMINS="$_HB_TMP_ADMIN"
}

test_qqbot_admin_ignores_plain_message() {
	_qa_setup
	qqbot_admin_handle GROUP_MESSAGE_CREATE '{"content":"hello"}' G1 "$_QA_ADMIN"
	assert_fail "plain group message is not a command"
	_qa_unsetup
}

test_qqbot_admin_rejects_non_admin() {
	_qa_setup
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!0000000000000000000000000000000B> <@!$_QA_P> 宝宝\"}" G1 "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
	assert_ok "non-admin bind is consumed (not relayed)"
	assert_contains "$_QA_REPLY" "只有管理员" "non-admin told why"
	assert_eq "$(cat "$_QA_STATE/qqbot-nick/G1" 2>/dev/null)" "" "non-admin writes nothing"
	_qa_unsetup
}

test_qqbot_admin_binds_by_mention() {
	_qa_setup
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!0000000000000000000000000000000B> <@!$_QA_P> 宝宝\"}" G1 "$_QA_ADMIN"
	assert_ok "admin bind by mention consumed"
	assert_eq "$(qqbot_nick_get G1 "$_QA_P")" "宝宝" "binding stored"
	assert_contains "$_QA_REPLY" "已绑定" "confirmation sent"
	_qa_unsetup
}

test_qqbot_admin_rebind_rewrites() {
	_qa_setup
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!0000000000000000000000000000000B> <@!$_QA_P> 宝宝\"}" G1 "$_QA_ADMIN"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!0000000000000000000000000000000B> <@!$_QA_P> 宝子\"}" G1 "$_QA_ADMIN"
	assert_eq "$(qqbot_nick_get G1 "$_QA_P")" "宝子" "latest binding wins"
	assert_eq "$(wc -l < "$_QA_STATE/qqbot-nick/G1")" "1" "no duplicate line"
	assert_contains "$_QA_REPLY" "已修改昵称" "rename reported as a change"
	assert_contains "$_QA_REPLY" "宝宝 → 宝子" "old and new names shown"
	_qa_unsetup
}

test_qqbot_admin_rebind_same_name() {
	_qa_setup
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!0000000000000000000000000000000B> <@!$_QA_P> 宝宝\"}" G1 "$_QA_ADMIN"
	assert_contains "$_QA_REPLY" "已绑定" "first bind says bound"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!0000000000000000000000000000000B> <@!$_QA_P> 宝宝\"}" G1 "$_QA_ADMIN"
	assert_contains "$_QA_REPLY" "昵称未变化" "same value reported as unchanged"
	_qa_unsetup
}

test_qqbot_admin_binds_by_prefix() {
	_qa_setup
	qqbot_hist_append G1 M1 "CBD5E00" "谷歌充值多少钱嘛"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!0000000000000000000000000000000B> CBD5E00 小明\"}" G1 "$_QA_ADMIN"
	assert_ok "admin bind by 7-char prefix consumed"
	assert_eq "$(qqbot_nick_get G1 "CBD5E00")" "小明" "prefix resolved via history"
	_qa_unsetup
}

test_qqbot_admin_unknown_prefix() {
	_qa_setup
	# not hex → ordinary chat, must still reach the relay
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!0000000000000000000000000000000B> ZZZZZZZ 无名\"}" G1 "$_QA_ADMIN"
	assert_fail "non-hex token is an ordinary message"
	assert_eq "$(cat "$_QA_STATE/qqbot-nick/G1" 2>/dev/null)" "" "nothing written"
	# hex but nobody matches → tool answers instead of silently relaying
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!0000000000000000000000000000000B> AAAAAAA 无名\"}" G1 "$_QA_ADMIN"
	assert_contains "$_QA_REPLY" "找不到" "unknown prefix reported"
	_qa_unsetup
}

test_qqbot_admin_sender_and_render_use_nick() {
	_qa_setup
	qqbot_nick_set G1 "$_QA_P" "宝宝"
	assert_eq "$(_sync_get_sender qqbot "{\"group_openid\":\"G1\",\"author\":{\"member_openid\":\"$_QA_P\"}}")" \
		"宝宝(qq#ABC1234)" "relay sender shows bound name"
	assert_eq "$(qqbot_render_content "<@$_QA_P> 说话" G1)" "@宝宝 说话" "mention renders as the name"
	assert_eq "$(qqbot_render_content "<@$_QA_P> 说话")" "@qq#ABC1234 说话" "no group → short id"
	_qa_unsetup
}

test_qqbot_admin_history_lists_ids() {
	_qa_setup
	qqbot_hist_append G1 M10 "$_QA_P" "第一句"
	qqbot_hist_append G1 M11 "$_QA_P" "第二句"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE '{"content":"<@!0000000000000000000000000000000B> 历史"}' G1 "$_QA_ADMIN"
	assert_ok "history consumed"
	assert_contains "$_QA_REPLY" "id=M10" "oldest id listed"
	assert_contains "$_QA_REPLY" "id=M11" "newest id listed"
	assert_contains "$_QA_REPLY" "第一句" "body listed"
	assert_contains "$_QA_REPLY" "第二句" "body listed"
	_qa_unsetup
}

test_qqbot_admin_history_keeps_limit() {
	_qa_setup
	QQBOT_HIST_KEEP=6
	_i=0
	while [ "$_i" -lt 10 ]; do
		qqbot_hist_append G1 "M$_i" "$_QA_P" "line $_i"
		_i=$((_i + 1))
	done
	assert_eq "$(wc -l < "$_QA_STATE/qqbot-hist/G1")" "6" "log trimmed to KEEP"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE '{"content":"<@!0000000000000000000000000000000B> 历史"}' G1 "$_QA_ADMIN"
	assert_not_contains "$_QA_REPLY" "line 0" "trimmed line not shown"
	assert_contains "$_QA_REPLY" "line 9" "newest line shown"
	QQBOT_HIST_KEEP=50
	_qa_unsetup
}


test_qqbot_admin_ignores_plain_message
test_qqbot_admin_rejects_non_admin
test_qqbot_admin_binds_by_mention
test_qqbot_admin_rebind_rewrites
test_qqbot_admin_binds_by_prefix
test_qqbot_admin_unknown_prefix
test_qqbot_admin_sender_and_render_use_nick
test_qqbot_admin_history_lists_ids
test_qqbot_admin_history_keeps_limit

_STATE_DIR="$_QA_OLD_STATE"
test_purge "$_QA_STATE"
