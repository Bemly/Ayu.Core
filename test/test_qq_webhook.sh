# QQ webhook parsing tests

test_webhook_message_receive() {
    _event='{"time":1,"self_id":1,"event_type":"message_receive","data":{"peer_id":1,"sender_id":111,"message_seq":1,"message_scene":"friend","segments":[{"type":"text","data":{"text":"hello"}}]}}'
    _result="$(qq_extract_text "$(json_get "$_event" data)")" && _rc=0 || _rc=$?
    assert_eq "$_result" "hello" "extract text from message_receive"
}

test_webhook_group_nudge() {
    _event='{"time":1,"self_id":1,"event_type":"group_nudge","data":{"group_id":100,"sender_id":222,"receiver_id":1}}'
    # Just verify it parses without error
    qq_webhook "$_event" 2>/dev/null
    assert_ok "webhook group_nudge parsed"
}

test_webhook_friend_request() {
    _event='{"time":1,"self_id":1,"event_type":"friend_request","data":{"initiator_id":333,"comment":"hi"}}'
    qq_webhook "$_event" 2>/dev/null
    assert_ok "webhook friend_request parsed"
}

test_webhook_bot_offline() {
    _event='{"time":1,"self_id":1,"event_type":"bot_offline","data":{"reason":"kick"}}'
    qq_webhook "$_event" 2>/dev/null
    assert_ok "webhook bot_offline parsed"
}

test_webhook_unknown_event() {
    _event='{"time":1,"self_id":1,"event_type":"weird_custom","data":{}}'
    qq_webhook "$_event" 2>/dev/null
    assert_ok "webhook unknown event doesnt crash"
}

test_webhook_member_decrease() {
    _event='{"time":1,"self_id":1,"event_type":"group_member_decrease","data":{"group_id":100,"user_id":333}}'
    qq_webhook "$_event" 2>/dev/null
    assert_ok "webhook group_member_decrease parsed"
}

test_webhook_message_recall() {
    _event='{"time":1,"self_id":1,"event_type":"message_recall","data":{"message_scene":"group","peer_id":100,"message_seq":5,"sender_id":111,"operator_id":222,"display_suffix":""}}'
    qq_webhook "$_event" 2>/dev/null
    assert_ok "webhook message_recall parsed"
}

test_qq_extract_image() {
	_r="$(qq_extract_text '{"segments":[{"type":"image","data":{"resource_id":"r1","temp_url":"http://x","width":800,"height":600}}]}')"
	assert_eq "$_r" "[图片]" "extract image segment"
}

test_qq_extract_face() {
	_r="$(qq_extract_text '{"segments":[{"type":"face","data":{"face_id":1}}]}')"
	assert_eq "$_r" "[表情]" "extract face segment"
}

test_qq_extract_record() {
	_r="$(qq_extract_text '{"segments":[{"type":"record","data":{"resource_id":"r1","duration":5}}]}')"
	assert_eq "$_r" "[语音]" "extract voice segment"
}

test_qq_extract_video() {
	_r="$(qq_extract_text '{"segments":[{"type":"video","data":{"resource_id":"r1","width":800,"height":600,"duration":30}}]}')"
	assert_eq "$_r" "[视频]" "extract video segment"
}

test_qq_extract_file() {
	_r="$(qq_extract_text '{"segments":[{"type":"file","data":{"file_id":"f1","file_name":"doc.pdf","file_size":1024}}]}')"
	assert_eq "$_r" "[文件: doc.pdf]" "extract file segment with name"
}

test_qq_extract_mention() {
	_r="$(qq_extract_text '{"segments":[{"type":"mention","data":{"user_id":123456}}]}')"
	assert_eq "$_r" "@123456" "extract mention segment"
}

test_qq_extract_mention_all() {
	_r="$(qq_extract_text '{"segments":[{"type":"mention_all","data":{}}]}')"
	assert_eq "$_r" "@所有人" "extract mention_all segment"
}

test_qq_extract_reply() {
	_r="$(qq_extract_text '{"segments":[{"type":"reply","data":{"message_seq":100}}]}')"
	assert_eq "$_r" "[回复]" "extract reply segment"
}

test_qq_extract_forward() {
	_r="$(qq_extract_text '{"segments":[{"type":"forward","data":{"forward_id":"fw1"}}]}')"
	assert_eq "$_r" "[转发]" "extract forward segment"
}

test_qq_extract_mixed() {
	_r="$(qq_extract_text '{"segments":[{"type":"text","data":{"text":"look"}},{"type":"image","data":{"resource_id":"r1"}}]}')"
	assert_eq "$_r" "look [图片]" "extract text+image mixed"
}

test_qq_extract_empty() {
	_r="$(qq_extract_text '{"segments":[]}')"
	assert_eq "$_r" "" "extract empty segments"
}

test_qq_extract_gif() {
	_r="$(qq_extract_text '{"segments":[{"type":"image","data":{"resource_id":"r1","temp_url":"http://x/a.gif","width":480,"height":360,"sub_type":1}}]}')"
	assert_eq "$_r" "[图片]" "extract GIF image segment (sub_type=1)"
}

test_qq_extract_static_image() {
	_r="$(qq_extract_text '{"segments":[{"type":"image","data":{"resource_id":"r2","temp_url":"http://x/b.jpg","width":800,"height":600,"sub_type":0}}]}')"
	assert_eq "$_r" "[图片]" "extract static image segment (sub_type=0)"
}

test_qq_extract_image
test_qq_extract_face
test_qq_extract_record
test_qq_extract_video
test_qq_extract_file
test_qq_extract_mention
test_qq_extract_mention_all
test_qq_extract_reply
test_qq_extract_forward
test_qq_extract_mixed
test_qq_extract_empty
test_qq_extract_gif
test_qq_extract_static_image
test_webhook_message_receive
test_webhook_group_nudge
test_webhook_friend_request
test_webhook_bot_offline
test_webhook_member_decrease
test_webhook_message_recall
test_webhook_unknown_event
