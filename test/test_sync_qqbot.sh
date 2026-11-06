# test/test_sync_qqbot.sh — QQ official bot ↔ TG / DC / QQ cross-post tests
# Mocked HTTP only: no bot accounts, no network.

. ./plugin/sync/handler.sh

# Isolate state: the real var/state holds other tests' maps.
_SQB_OLD_STATE="$_STATE_DIR"
_SQB_STATE="/tmp/sync-qqbot-state-$$"
mkdir -p "$_SQB_STATE" 2>/dev/null
_STATE_DIR="$_SQB_STATE"

_sqb_conf() {
	_SYNC_CONF="/tmp/sync-qqbot-test-$$.conf"
	printf '%s\n' "$1" > "$_SYNC_CONF"
}

# Attachment bytes come from the CDN, so stub the downloader (no network).
_sqb_stub_download() {
	http_get_file() {
		mkdir -p "$(dirname "$2")" 2>/dev/null
		printf 'FAKEDATA' > "$2"
		return 0
	}
}

_sqb_restore_download() {
	. ./lib/http.sh
}

# Minimal group event as the webhook hands it to dispatch (already unwrapped).
_sqb_raw() {
	printf '%s' '{"id":"MSG1","content":"hello","group_openid":"G1","author":{"id":"A1","member_openid":"MEM1"},"timestamp":"2026-11-06T10:00:00+08:00"}'
}

_sqb_raw_att() {
	printf '%s' '{"id":"MSG2","content":"pic","group_openid":"G1","author":{"id":"A1","member_openid":"MEM1"},"attachments":[{"content_type":"image/png","filename":"a.png","size":1234,"url":"https://cdn.example/a.png"}]}'
}

test_sync_qqbot_to_telegram() {
	_sqb_conf 'qqbot/group/G1=telegram/-200'
	mock_set '{"ok":true,"result":{"message_id":99}}'
	sync_handler "qqbot" "group_message" "MEM1" "hello" "$(_sqb_raw)" 2>/dev/null
	assert_ok "sync qqbot→telegram"
	# reverse map must be keyed by the bare source id so recall can find it
	assert_eq "$(cat "$_STATE_DIR/msg-map-rev/G1/MSG1" 2>/dev/null)" "telegram -200 99" "qqbot rev-map (tg side)"
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_to_discord() {
	_sqb_conf 'qqbot/group/G1=discord/300'
	mock_set '{"id":"dc1","content":"x"}'
	sync_handler "qqbot" "group_message" "MEM1" "hello" "$(_sqb_raw)" 2>/dev/null
	assert_ok "sync qqbot→discord"
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_to_qq_group() {
	_sqb_conf 'qqbot/group/G1=qq/group/100'
	mock_set '{"status":"ok","retcode":0,"data":{"message_seq":7,"time":1}}'
	sync_handler "qqbot" "group_message" "MEM1" "hello" "$(_sqb_raw)" 2>/dev/null
	assert_ok "sync qqbot→qq group"
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_to_qqbot_group() {
	_sqb_conf 'qqbot/group/G1=qqbot/group/G2'
	mock_set '{"id":"NEW9","timestamp":"2026-11-06T10:00:01+08:00"}'
	sync_handler "qqbot" "group_message" "MEM1" "hello" "$(_sqb_raw)" 2>/dev/null
	assert_ok "sync qqbot→qqbot group"
	# several targets may share one source message → the map is append-only
	assert_eq "$(tail -1 "$_STATE_DIR/msg-map-rev/G1/MSG1" 2>/dev/null)" "qqbot G2 NEW9" "qqbot→qqbot rev-map"
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_to_qqbot_c2c() {
	_sqb_conf 'qqbot/private/MEM1=qqbot/private/OID2'
	mock_set '{"id":"NEW10","timestamp":"2026-11-06T10:00:02+08:00"}'
	sync_handler "qqbot" "c2c_message" "MEM1" "hello" "$(_sqb_raw)" 2>/dev/null
	assert_ok "sync qqbot→qqbot c2c"
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_image_to_telegram() {
	_sqb_conf 'qqbot/group/G1=telegram/-200'
	_sqb_stub_download
	mock_set '{"ok":true,"result":{"message_id":99}}'
	sync_handler "qqbot" "group_message" "MEM1" "[图片] a.png" "$(_sqb_raw_att)" 2>/dev/null
	assert_ok "sync qqbot image→telegram multipart upload"
	_sqb_restore_download
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_image_to_discord() {
	_sqb_conf 'qqbot/group/G1=discord/300'
	_sqb_stub_download
	mock_set '{"id":"dc2","content":"x"}'
	sync_handler "qqbot" "group_message" "MEM1" "[图片] a.png" "$(_sqb_raw_att)" 2>/dev/null
	assert_ok "sync qqbot image→discord multipart upload"
	_sqb_restore_download
	rm -f "$_SYNC_CONF"
}

test_sync_qq_recall_to_qqbot() {
	# Pretend the qqbot copy was recorded earlier, then recall the qq original.
	mkdir -p "$_STATE_DIR/msg-map-rev/100" 2>/dev/null
	printf 'qqbot 200 m9\n' > "$_STATE_DIR/msg-map-rev/100/5"
	mock_set '{"code":0}'
	_raw_recall='{"message_scene":"group","peer_id":100,"message_seq":5,"sender_id":111,"operator_id":111}'
	sync_handler "qq" "message_recall" "111" "[撤回消息]" "$_raw_recall" 2>/dev/null
	assert_ok "sync qq recall → qqbot deleteMessage"
	rm -f "$_STATE_DIR/msg-map-rev/100/5"
}

test_sync_qqbot_no_conf() {
	_SYNC_CONF="/tmp/sync-qqbot-none-$$.conf"
	: > "$_SYNC_CONF"
	sync_handler "qqbot" "group_message" "MEM1" "hello" "$(_sqb_raw)" 2>/dev/null
	assert_ok "sync qqbot with empty conf is a no-op"
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_loop_prefix() {
	_SYNC_CONF="/tmp/sync-qqbot-loop-$$.conf"
	printf 'qqbot/group/G1=telegram/-200\n' > "$_SYNC_CONF"
	mock_fail
	sync_handler "qqbot" "group_message" "MEM1" "🅠 qq#MEM1: hi" "$(_sqb_raw)" 2>/dev/null
	assert_ok "loop-prevention drops 🅠-prefixed text"
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_to_telegram
test_sync_qqbot_to_discord
test_sync_qqbot_to_qq_group
test_sync_qqbot_to_qqbot_group
test_sync_qqbot_to_qqbot_c2c
test_sync_qqbot_image_to_telegram
test_sync_qqbot_image_to_discord
test_sync_qq_recall_to_qqbot
test_sync_qqbot_no_conf
test_sync_qqbot_loop_prefix

# restore for any later test file
_STATE_DIR="$_SQB_OLD_STATE"
test_purge "$_SQB_STATE"
