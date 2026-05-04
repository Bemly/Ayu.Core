# test/test_sync.sh — cross-platform sync tests (no accounts needed)
# Uses mock_http to simulate API responses

. ./plugin/sync.sh

test_sync_qq_to_telegram() {
    _SYNC_CONF="/tmp/sync-test-$$.conf"
    printf 'qq/group/100=telegram/-200\n' > "$_SYNC_CONF"
    mock_set '{"ok":true,"result":{"message_id":99}}'

    _raw='{"peer_id":100,"sender_id":111,"message_seq":1,"message_scene":"group","group_id":100,"group_member":{"user_id":111,"nickname":"Alice"},"segments":[{"type":"text","data":{"text":"hello"}}]}'
    sync_handler "qq" "message" "111" "hello" "$_raw" 2>/dev/null
    assert_ok "sync qq→telegram"
    rm -f "$_SYNC_CONF"
}

test_sync_qq_to_discord() {
    _SYNC_CONF="/tmp/sync-test-$$.conf"
    printf 'qq/group/100=discord/300\n' > "$_SYNC_CONF"
    mock_set '{"id":"msg1","content":"discord msg"}'

    _raw='{"peer_id":100,"sender_id":111,"message_seq":1,"message_scene":"group","group_id":100,"group_member":{"user_id":111,"nickname":"Alice"},"segments":[{"type":"text","data":{"text":"hello"}}]}'
    sync_handler "qq" "message" "111" "hello" "$_raw" 2>/dev/null
    assert_ok "sync qq→discord"
    rm -f "$_SYNC_CONF"
}

test_sync_telegram_to_qq() {
    _SYNC_CONF="/tmp/sync-test-$$.conf"
    printf 'telegram/-200=qq/group/100\n' > "$_SYNC_CONF"
    mock_set '{"status":"ok","retcode":0,"data":{"message_seq":1,"time":1}}'

    _raw='{"message_id":1,"from":{"id":222,"is_bot":false,"first_name":"Bob"},"chat":{"id":-200,"type":"group","title":"Test"},"date":1234567890,"text":"hi from tg"}'
    sync_handler "telegram" "message" "" "hi from tg" "$_raw" 2>/dev/null
    assert_ok "sync telegram→qq"
    rm -f "$_SYNC_CONF"
}

test_sync_telegram_to_discord() {
    _SYNC_CONF="/tmp/sync-test-$$.conf"
    printf 'telegram/-200=discord/300\n' > "$_SYNC_CONF"
    mock_set '{"id":"msg2","content":"discord msg"}'

    _raw='{"message_id":1,"from":{"id":222,"is_bot":false,"first_name":"Bob"},"chat":{"id":-200,"type":"group","title":"Test"},"date":1234567890,"text":"hi from tg"}'
    sync_handler "telegram" "message" "" "hi from tg" "$_raw" 2>/dev/null
    assert_ok "sync telegram→discord"
    rm -f "$_SYNC_CONF"
}

test_sync_group_nudge() {
    _SYNC_CONF="/tmp/sync-test-$$.conf"
    printf 'qq/group/100=telegram/-200\n' > "$_SYNC_CONF"
    mock_set '{"ok":true,"result":{"message_id":99}}'

    _raw='{"group_id":100,"sender_id":111,"receiver_id":222}'
    sync_handler "qq" "group_nudge" "111" "nudge" "$_raw" 2>/dev/null
    assert_ok "sync group_nudge → [戳一戳]"
    rm -f "$_SYNC_CONF"
}

test_sync_member_leave() {
    _SYNC_CONF="/tmp/sync-test-$$.conf"
    printf 'qq/group/100=telegram/-200\n' > "$_SYNC_CONF"
    mock_set '{"ok":true,"result":{"message_id":99}}'

    _raw='{"group_id":100,"user_id":333}'
    sync_handler "qq" "member_leave" "333" "leave" "$_raw" 2>/dev/null
    assert_ok "sync member_leave → [成员离开]"
    rm -f "$_SYNC_CONF"
}

test_sync_no_source_id() {
    sync_handler "qq" "message" "111" "hello" "{}" 2>/dev/null
    assert_ok "sync returns ok when cannot determine source"
}

test_sync_skip_sync_prefix() {
    sync_handler "qq" "message" "111" "✈️ Bob: hello" "{}" 2>/dev/null
    assert_ok "sync skips emoji-prefixed messages"
}

test_sync_no_config() {
    _SYNC_CONF="/tmp/sync-test-$$.conf"
    printf 'qq/group/999=telegram/-888\n' > "$_SYNC_CONF"

    _raw='{"peer_id":100,"sender_id":111,"message_seq":1,"message_scene":"group","group_id":100,"segments":[{"type":"text","data":{"text":"hello"}}]}'
    sync_handler "qq" "message" "111" "hello" "$_raw" 2>/dev/null
    assert_ok "sync handles no matching config"
    rm -f "$_SYNC_CONF"
}

test_sync_missing_config_file() {
    _SYNC_CONF="/tmp/nonexistent-sync-$$.conf"
    sync_handler "qq" "message" "111" "hello" "{}" 2>/dev/null
    assert_ok "sync handles missing config file"
}

test_sync_api_fail() {
    _SYNC_CONF="/tmp/sync-test-$$.conf"
    printf 'qq/group/100=telegram/-200\n' > "$_SYNC_CONF"
    mock_fail

    _raw='{"peer_id":100,"sender_id":111,"message_seq":1,"message_scene":"group","group_id":100,"group_member":{"user_id":111,"nickname":"Alice"},"segments":[{"type":"text","data":{"text":"hello"}}]}'
    sync_handler "qq" "message" "111" "hello" "$_raw" 2>/dev/null
    assert_ok "sync survives API failure (best-effort)"
    rm -f "$_SYNC_CONF"
}

test_sync_multi_target() {
    _SYNC_CONF="/tmp/sync-test-$$.conf"
    printf 'qq/group/100=telegram/-200\n' > "$_SYNC_CONF"
    printf 'qq/group/100=discord/300\n' >> "$_SYNC_CONF"
    mock_set '{"ok":true,"result":{"message_id":99}}'

    _raw='{"peer_id":100,"sender_id":111,"message_seq":1,"message_scene":"group","group_id":100,"group_member":{"user_id":111,"nickname":"Alice"},"segments":[{"type":"text","data":{"text":"hello"}}]}'
    sync_handler "qq" "message" "111" "hello" "$_raw" 2>/dev/null
    assert_ok "sync multi-target (qq→tg+dc)"
    rm -f "$_SYNC_CONF"
}

test_sync_qq_gif_to_tg() {
	_SYNC_CONF="/tmp/sync-test-$$.conf"
	printf 'qq/group/100=telegram/-200\n' > "$_SYNC_CONF"
	mock_set '{"ok":true,"result":{"message_id":99}}'

	_raw='{"peer_id":100,"sender_id":111,"message_seq":1,"message_scene":"group","group_id":100,"group_member":{"user_id":111,"nickname":"Alice"},"segments":[{"type":"image","data":{"resource_id":"r1","temp_url":"http://x.com/a.gif","width":480,"height":360,"summary":"[图片]","sub_type":1}}]}'
	sync_handler "qq" "message" "111" "[图片]" "$_raw" 2>/dev/null
	assert_ok "sync qq→tg GIF (sub_type=1 → sendAnimation)"
	rm -f "$_SYNC_CONF"
}

test_sync_qq_static_image_to_tg() {
	_SYNC_CONF="/tmp/sync-test-$$.conf"
	printf 'qq/group/100=telegram/-200\n' > "$_SYNC_CONF"
	mock_set '{"ok":true,"result":{"message_id":99}}'

	_raw='{"peer_id":100,"sender_id":111,"message_seq":1,"message_scene":"group","group_id":100,"group_member":{"user_id":111,"nickname":"Alice"},"segments":[{"type":"image","data":{"resource_id":"r2","temp_url":"http://x.com/b.jpg","width":800,"height":600,"summary":"[图片]","sub_type":0}}]}'
	sync_handler "qq" "message" "111" "[图片]" "$_raw" 2>/dev/null
	assert_ok "sync qq→tg static image (sub_type=0 → sendPhoto)"
	rm -f "$_SYNC_CONF"
}

test_sync_tg_animation_to_qq() {
	_SYNC_CONF="/tmp/sync-test-$$.conf"
	printf 'telegram/-200=qq/group/100\n' > "$_SYNC_CONF"
	mock_set '{"ok":true,"result":{"file_path":"animations/file_0.mp4"}}'

	_raw='{"message_id":1,"from":{"id":222,"is_bot":false,"first_name":"Bob"},"chat":{"id":-200,"type":"group","title":"Test"},"animation":{"file_id":"anim1","file_unique_id":"uq1","width":480,"height":360,"duration":3},"caption":"gif test"}'
	sync_handler "telegram" "message" "" "gif test" "$_raw" 2>/dev/null
	assert_ok "sync tg→qq animation forwarding"
	rm -f "$_SYNC_CONF"
}

test_sync_qq_to_telegram
test_sync_qq_to_discord
test_sync_telegram_to_qq
test_sync_telegram_to_discord
test_sync_group_nudge
test_sync_member_leave
test_sync_skip_sync_prefix
test_sync_no_config
test_sync_missing_config_file
test_sync_api_fail
test_sync_multi_target
test_sync_qq_gif_to_tg
test_sync_qq_static_image_to_tg
test_sync_tg_animation_to_qq
