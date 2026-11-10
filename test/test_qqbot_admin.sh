# test/test_qqbot_admin.sh — group commands: history + platform nickname cache
#
# The official API exposes no nickname table to maintain: names come from
# `author.username`, cached per group. These tests cover the history command,
# its permission gate, both event shapes, and the cached-name path used by
# mention rendering and the relay sender.

_QA_STATE="$(mktemp -d)"
_QA_OLD_STATE="$_STATE_DIR"
_STATE_DIR="$_QA_STATE"
_HB_TMP_ADMIN="${QQBOT_ADMINS:-}"
_HB_TMP_BOT_ID="${QQBOT_BOT_OPENID:-}"

. ./plugin/sync/common.sh

_QA_ADMIN="9DB40F24307A212B6FE37AA4C0BD1A8E"
_QA_BOT="0000000000000000000000000000000B"
_QA_P="ABC1234D9F19B085571787A9E0F3C0B6"

# capture the reply instead of calling the API
_qa_setup() {
	_QA_REPLY=""
	mkdir -p "$_QA_STATE"
	rm -rf "$_QA_STATE/qqbot-hist" "$_QA_STATE/qqbot-nick-auto"
	QQBOT_HIST_DIR="$_QA_STATE/qqbot-hist"
	QQBOT_NICK_AUTO_DIR="$_QA_STATE/qqbot-nick-auto"
	QQBOT_ADMINS="$_QA_ADMIN"
	# a real bot id in etc/config.sh would reject the fake mentions below
	QQBOT_BOT_OPENID=""
	qqbot_reply_event() { _QA_REPLY="$2"; }
}
_qa_unsetup() {
	QQBOT_HIST_DIR="${_QA_STATE}/qqbot-hist"
	QQBOT_ADMINS="$_HB_TMP_ADMIN"
	QQBOT_BOT_OPENID="$_HB_TMP_BOT_ID"
}

test_qqbot_admin_ignores_plain_message() {
	_qa_setup
	qqbot_admin_handle GROUP_MESSAGE_CREATE '{"content":"hello"}' G1 "$_QA_ADMIN"
	assert_fail "plain group message is not a command"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!$_QA_BOT> 今天 天气不错\"}" G1 "$_QA_ADMIN"
	assert_fail "plain chat that mentions the bot is not a command"
	_qa_unsetup
}

test_qqbot_admin_history_requires_admin() {
	_qa_setup
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!$_QA_BOT> 历史\"}" G1 "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
	assert_ok "non-admin history is consumed (not relayed)"
	assert_contains "$_QA_REPLY" "只有管理员" "non-admin told why"
	_qa_unsetup
}

test_qqbot_admin_platform_nick_cached_from_event() {
	_qa_setup
	assert_eq "$(qqbot_nick_auto_get G1 "$_QA_P")" "" "no cached name before an event"
	qqbot_nick_auto_set G1 "$_QA_P" "小明"
	assert_eq "$(qqbot_nick_auto_get G1 "$_QA_P")" "小明" "platform name cached"
	assert_eq "$(qqbot_render_content "<@$_QA_P> 说话" G1)" "@小明 说话" "mention renders the cached name"
	assert_eq "$(qqbot_render_content "<@$_QA_P> 说话")" "@qq#ABC1234 说话" "no group → short id"
	qqbot_nick_auto_set G1 "$_QA_P" "小明"
	assert_eq "$(wc -l < "$_QA_STATE/qqbot-nick-auto/G1")" "1" "same name does not append a line"
	qqbot_nick_auto_set G1 "$_QA_P" "小红"
	assert_eq "$(qqbot_nick_auto_get G1 "$_QA_P")" "小红" "latest platform name wins"
	assert_eq "$(wc -l < "$_QA_STATE/qqbot-nick-auto/G1")" "1" "no duplicate line per member"
	_qa_unsetup
}

test_qqbot_admin_sender_uses_cached_nick() {
	_qa_setup
	qqbot_nick_auto_set G1 "$_QA_P" "小明"
	assert_eq "$(_sync_get_sender qqbot "{\"group_openid\":\"G1\",\"author\":{\"member_openid\":\"$_QA_P\"}}")" \
		"小明(qq#ABC1234)" "relay sender shows the cached name"
	assert_eq "$(_sync_get_sender qqbot "{\"group_openid\":\"G1\",\"author\":{\"member_openid\":\"$_QA_P\",\"username\":\"小红\"}}")" \
		"小红(qq#ABC1234)" "event username is used verbatim"
	_qa_unsetup
}

test_qqbot_admin_webhook_caches_author_username() {
	_qa_setup
	dispatch() { return 0; }
	qqbot_handle_event GROUP_AT_MESSAGE_CREATE \
		'{"id":"M1","content":"hi","group_openid":"G1","author":{"member_openid":"'"$_QA_P"'","username":"小明","bot":false}}' '{}'
	assert_eq "$(qqbot_nick_auto_get G1 "$_QA_P")" "小明" "inbound event caches author.username"
	qqbot_handle_event GROUP_AT_MESSAGE_CREATE \
		'{"id":"M2","content":"hi","group_openid":"G1","author":{"member_openid":"'"$_QA_P"'","username":"","bot":false}}' '{}'
	assert_eq "$(qqbot_nick_auto_get G1 "$_QA_P")" "小明" "empty username leaves the cache alone"
	_qa_unsetup
}

test_qqbot_admin_history_lists_ids() {
	_qa_setup
	qqbot_hist_append G1 M10 "$_QA_P" "第一句"
	qqbot_hist_append G1 M11 "$_QA_P" "第二句"
	qqbot_nick_auto_set G1 "$_QA_P" "小明"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE '{"content":"<@!0000000000000000000000000000000B> 历史"}' G1 "$_QA_ADMIN"
	assert_ok "history consumed"
	assert_contains "$_QA_REPLY" "id=M10" "oldest id listed"
	assert_contains "$_QA_REPLY" "id=M11" "newest id listed"
	assert_contains "$_QA_REPLY" "第一句" "body listed"
	assert_contains "$_QA_REPLY" "第二句" "body listed"
	assert_contains "$_QA_REPLY" "小明" "cached platform name shown instead of qq#"
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

# QQ HTML-escapes the angle brackets of a mention: content arrives as
# `\u003c@openid\u003e` (literal backslash-u, one JSON layer down). Commands must
# still be recognised, otherwise they are relayed and never answered.
test_qqbot_admin_escaped_mentions() {
	_qa_setup
	qqbot_hist_append G1 M12 "$_QA_P" "转义句"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		'{"content":"\\u003c@0000000000000000000000000000000B\\u003e 历史"}' G1 "$_QA_ADMIN"
	assert_ok "escaped history consumed"
	assert_contains "$_QA_REPLY" "转义句" "escaped history replies with the log"
	_qa_unsetup
}

# A bot subscribed to the full group stream receives @-messages as
# GROUP_MESSAGE_CREATE — QQ never sends GROUP_AT_MESSAGE_CREATE in that mode.
# Commands have to work there too, while plain chatter must stay untouched.
test_qqbot_admin_full_stream_commands() {
	_qa_setup
	qqbot_hist_append G1 M20 "$_QA_P" "测试句"
	qqbot_admin_handle GROUP_MESSAGE_CREATE \
		'{"content":"<@0000000000000000000000000000000B> 历史"}' G1 "$_QA_ADMIN"
	assert_ok "full-stream history consumed"
	assert_contains "$_QA_REPLY" "最近" "full-stream history replied"
	assert_contains "$_QA_REPLY" "测试句" "full-stream history body"
	_qa_unsetup
}

test_qqbot_admin_full_stream_requires_bot_mention() {
	_qa_setup
	QQBOT_BOT_OPENID="0000000000000000000000000000000B"
	qqbot_admin_handle GROUP_MESSAGE_CREATE \
		"{\"content\":\"<@$_QA_P> 历史\"}" G1 "$_QA_ADMIN"
	assert_fail "mention of somebody else is not a command"
	qqbot_admin_handle GROUP_MESSAGE_CREATE \
		'{"content":"<@0000000000000000000000000000000B> 历史"}' G1 "$_QA_ADMIN"
	assert_ok "bot mention is still a command"
	_qa_unsetup
}

# No binding table survives: the former command forms must be ordinary chat.
test_qqbot_admin_no_bind_commands() {
	_qa_setup
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!$_QA_BOT> <@!$_QA_P> 宝宝\"}" G1 "$_QA_ADMIN"
	assert_fail "bind by mention is no longer a command"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!$_QA_BOT> ABC1234 宝宝\"}" G1 "$_QA_ADMIN"
	assert_fail "bind by prefix is no longer a command"
	qqbot_admin_handle GROUP_AT_MESSAGE_CREATE \
		"{\"content\":\"<@!$_QA_BOT> 蓝莓小果冻\"}" G1 "$_QA_P"
	assert_fail "self rename is no longer a command"
	if [ -e "$_QA_STATE/qqbot-nick" ]; then false; else true; fi
	assert_ok "no binding state written"
	_qa_unsetup
}

test_qqbot_admin_full_stream_commands
test_qqbot_admin_full_stream_requires_bot_mention
test_qqbot_admin_escaped_mentions
test_qqbot_admin_ignores_plain_message
test_qqbot_admin_history_requires_admin
test_qqbot_admin_platform_nick_cached_from_event
test_qqbot_admin_sender_uses_cached_nick
test_qqbot_admin_webhook_caches_author_username
test_qqbot_admin_history_lists_ids
test_qqbot_admin_history_keeps_limit
test_qqbot_admin_no_bind_commands

_STATE_DIR="$_QA_OLD_STATE"
test_purge "$_QA_STATE"
