# test/test_qqbot_interaction.sh — INTERACTION_CREATE button payload
#
# QQ 按钮回调的载荷在 d.data.resolved 里（button_id / button_data / message_id），
# 部分版本把 button_data 直接挂在 d.data 下。webhook 负责把它拍平成事件文本
# `interaction:INTERACTION_CREATE button=<id> data=<data> msg=<mid>`，否则 handler
# 只看到空壳事件名，做不了按按钮分流。这里断言这条链路，以及 11/12 才自动 ACK。

_QI_TMP="$(mktemp -d)"
_QI_OLD_DEDUP="${QQBOT_DEDUP_FILE:-}"
_QI_OLD_SIG="${QQBOT_VERIFY_SIG:-}"
_QI_OLD_ACK="${QQBOT_INTERACTION_AUTOACK:-}"

_qi_stub() {
	_QI_D="$_QI_TMP/dispatch"
	_QI_A="$_QI_TMP/ack"
	: >"$_QI_D"
	: >"$_QI_A"
	dispatch() { printf '%s|%s|%s\n' "$1" "$2" "$4" >>"$_QI_D"; }
	qqbot_interaction_ack() { printf '%s %s\n' "$1" "$2" >>"$_QI_A"; return 0; }
	QQBOT_VERIFY_SIG=0
	QQBOT_INTERACTION_AUTOACK=1
	QQBOT_DEDUP_FILE="$_QI_TMP/dedup-$1"
}

_qi_restore() {
	QQBOT_DEDUP_FILE="$_QI_OLD_DEDUP"
	QQBOT_VERIFY_SIG="$_QI_OLD_SIG"
	QQBOT_INTERACTION_AUTOACK="$_QI_OLD_ACK"
	. ./lib/dispatch.sh
	. ./adapter/qqbot/core.sh
}

test_qqbot_interaction_resolved_payload() {
	_qi_stub r1
	_body='{"op":0,"id":"QI-EV-1","t":"INTERACTION_CREATE","d":{"id":"INT-1","type":11,"scene":"group","chat_type":0,"group_openid":"G1","group_member_openid":"M1","data":{"resolved":{"button_id":"b1","button_data":"page=2","user_id":"U1","message_id":"MID1"}}}}'
	qqbot_webhook "$_body" >/dev/null 2>&1
	_line="$(cat "$_QI_D")"
	assert_contains "$_line" "qqbot|interaction" "interaction dispatched as qqbot/interaction"
	assert_contains "$_line" "button=b1" "button id reaches event text"
	assert_contains "$_line" "data=page=2" "button data reaches event text"
	assert_contains "$_line" "msg=MID1" "message id reaches event text"
	assert_contains "$(cat "$_QI_A")" "INT-1 0" "type=11 auto-acked with code 0"
	_qi_restore
}

test_qqbot_interaction_flat_button_data() {
	_qi_stub r2
	_body='{"op":0,"id":"QI-EV-2","t":"INTERACTION_CREATE","d":{"id":"INT-2","type":11,"scene":"group","chat_type":0,"group_member_openid":"M1","data":{"type":11,"button_id":"b2","button_data":"act=undo"}}}'
	qqbot_webhook "$_body" >/dev/null 2>&1
	_line="$(cat "$_QI_D")"
	assert_contains "$_line" "button=b2" "flat button id reaches event text"
	assert_contains "$_line" "data=act=undo" "flat button data reaches event text"
	_qi_restore
}

test_qqbot_interaction_type14_not_acked() {
	_qi_stub r3
	_body='{"op":0,"id":"QI-EV-3","t":"INTERACTION_CREATE","d":{"id":"INT-3","type":14,"scene":"group","chat_type":0,"group_member_openid":"M1","data":{"type":14}}}'
	qqbot_webhook "$_body" >/dev/null 2>&1
	assert_not_contains "$(cat "$_QI_A")" "INT-3" "type=14 must not be acked"
	_qi_restore
}

test_qqbot_interaction_without_payload() {
	_qi_stub r4
	_body='{"op":0,"id":"QI-EV-4","t":"INTERACTION_CREATE","d":{"id":"INT-4","type":11,"scene":"group","chat_type":0,"group_member_openid":"M1","data":{}}}'
	qqbot_webhook "$_body" >/dev/null 2>&1
	_line="$(cat "$_QI_D")"
	assert_contains "$_line" "interaction:INTERACTION_CREATE" "bare interaction still dispatched"
	assert_not_contains "$_line" "button=" "no button id when payload is empty"
	_qi_restore
}

test_qqbot_interaction_resolved_payload
test_qqbot_interaction_flat_button_data
test_qqbot_interaction_type14_not_acked
test_qqbot_interaction_without_payload
