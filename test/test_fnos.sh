# test/test_fnos.sh — fnOS (飞牛) inbound notification channel
# Mocked HTTP only: the relay path is asserted through MOCK_LOG, no network.

. ./adapter/fnos/webhook.sh
. ./adapter/qqbot/core.sh
. ./adapter/qqbot/message.sh

_FN_OLD_STATE="$_STATE_DIR"
_FN_STATE="/tmp/fnos-test-$$"
mkdir -p "$_FN_STATE" 2>/dev/null
_STATE_DIR="$_FN_STATE"
QQBOT_TOKEN_FILE="$_FN_STATE/qqbot-token.json"
printf '{"access_token":"tok","expires_at":9999999999}' > "$QQBOT_TOKEN_FILE"
_FN_OLD_TO="${FNOS_NOTIFY_TO:-}"
FNOS_NOTIFY_TO=""

# ---- payload parsing ------------------------------------------------------

test_fnos_parse_dingtalk() {
	assert_eq "$(_fnos_text '{"msgtype":"text","text":{"content":"磁盘告警"}}')" \
		"磁盘告警" "fnos: dingtalk/wecom text.content"
}

test_fnos_parse_feishu() {
	assert_eq "$(_fnos_text '{"msg_type":"text","content":{"text":"飞书告警"}}')" \
		"飞书告警" "fnos: feishu content.text"
}

test_fnos_parse_flat_text() {
	assert_eq "$(_fnos_text '{"title":"t","text":"纯文本告警"}')" \
		"纯文本告警" "fnos: flat text field"
}

test_fnos_parse_unknown_shape_is_empty() {
	assert_eq "$(_fnos_text '{"foo":"bar"}')" "" "fnos: unknown shape yields empty text"
}

# fnOS posts its own {"title","body"} shape (no bridge involved); `body` carries
# the alert. Missing it made the whole JSON go out as the message body, which the
# QQ Bot API rejects with 50015001.
test_fnos_parse_native_body() {
	assert_eq "$(_fnos_text '{"title":"qq-测试推送","body":"设备名称：MEminiFnOS 告警详情：测试消息"}')" \
		"设备名称：MEminiFnOS 告警详情：测试消息" "fnos: native title/body shape"
}

# Fallback text must not start with `{"`: QQ Bot answers 50015001 for it.
test_fnos_fallback_strips_json_punctuation() {
	assert_eq "$(_fnos_fallback '{"foo":"bar"}')" "foo:bar" "fnos: fallback drops JSON punctuation"
	assert_not_contains "$(_fnos_fallback '{"foo":"bar"}')" "{" "fnos: fallback has no braces"
}

# fnOS embeds line breaks as JSON escapes; relaying them verbatim put a literal
# "\n" inside every alert.
test_fnos_unescape_newlines() {
	assert_eq "$(_fnos_unescape '第一行\n第二行')" "第一行
第二行" "fnos: escaped newlines become real ones"
}

# ---- relay ----------------------------------------------------------------

test_fnos_relay_qqbot_private() {
	FNOS_NOTIFY_TO="qqbot:private/U1"
	mock_req_reset
	mock_set '{"id":"m1","timestamp":"2026-11-07T10:00:00+08:00"}'
	fnos_webhook '{"msgtype":"text","text":{"content":"磁盘告警"}}' 2>/dev/null
	assert_eq "$(mock_req_count)" "1" "fnos: one relay request"
	assert_contains "$(mock_last_url)" "/v2/users/U1/messages" "fnos: relay hits the c2c endpoint"
	FNOS_NOTIFY_TO=""
}

test_fnos_relay_unknown_target_is_skipped() {
	FNOS_NOTIFY_TO="bogus:x"
	mock_req_reset
	fnos_webhook '{"text":"x"}' 2>/dev/null
	assert_eq "$(mock_req_count)" "0" "fnos: unknown platform sends nothing"
	FNOS_NOTIFY_TO=""
}

test_fnos_empty_body_accepted() {
	mock_req_reset
	fnos_webhook '' 2>/dev/null
	assert_ok "fnos: empty body still returns success"
	assert_eq "$(mock_req_count)" "0" "fnos: empty body sends nothing"
}

# The HTTP answer must stay success even when a relay fails: fnOS retries any
# non-zero errcode forever, and a dead target cannot be fixed by a retry.
test_fnos_relay_failure_still_ok() {
	FNOS_NOTIFY_TO="qqbot:private/U1"
	mock_fail 1
	fnos_webhook '{"text":"磁盘告警"}' 2>/dev/null
	assert_ok "fnos: relay failure keeps the handler successful"
	FNOS_NOTIFY_TO=""
}

# ---- run ------------------------------------------------------------------

test_fnos_parse_dingtalk
test_fnos_parse_feishu
test_fnos_parse_flat_text
test_fnos_parse_unknown_shape_is_empty
test_fnos_parse_native_body
test_fnos_fallback_strips_json_punctuation
test_fnos_unescape_newlines

test_fnos_relay_qqbot_private
test_fnos_relay_unknown_target_is_skipped
test_fnos_empty_body_accepted
test_fnos_relay_failure_still_ok

# leave the mock healthy for later test files
mock_set ''

# ---- teardown -------------------------------------------------------------

test_purge "$_FN_STATE"
_STATE_DIR="$_FN_OLD_STATE"
FNOS_NOTIFY_TO="$_FN_OLD_TO"
