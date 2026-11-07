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

# Regression: a forward *into* the QQ official bot must keep the source icon
# and sender prefix. The bug was that the qqbot branch sent the raw `_txt_safe`
# instead of `_text_safe`, so tg/dc relays arrived as bare text.
# The send happens inside `$(...)`, i.e. a subshell, so the captured text has
# to go through a file instead of a variable.
_sqb_capture_group_send() {
	: > "$_SQB_STATE/sent"
	qqbot_message_send_group() {
		printf '%s' "$2" > "$_SQB_STATE/sent"
		printf '{"id":"CAP1","timestamp":"2026-11-06T10:00:03+08:00"}'
	}
}

_sqb_raw_tg() {
	printf '%s' '{"message_id":77,"text":"hi","from":{"id":555,"first_name":"Bob","username":"bob"},"chat":{"id":-200}}'
}

_sqb_raw_dc() {
	printf '%s' '{"id":"D1","content":"hi","channel_id":"300","author":{"id":"u9","username":"carol","global_name":"Carol"}}'
}

test_sync_telegram_to_qqbot_prefix() {
	_sqb_conf 'telegram/-200=qqbot/group/G2'
	_sqb_capture_group_send
	sync_handler "telegram" "message" "555" "hi" "$(_sqb_raw_tg)" 2>/dev/null
	assert_contains "$(cat "$_SQB_STATE/sent" 2>/dev/null)" "✈️ Bob(@bob): hi" "telegram→qqbot keeps ✈️ + sender"
	. "$_HB/adapter/qqbot/message.sh"
	rm -f "$_SYNC_CONF"
}

test_sync_discord_to_qqbot_prefix() {
	_sqb_conf 'discord/300=qqbot/group/G2'
	_sqb_capture_group_send
	sync_handler "discord" "message" "u9" "hi" "$(_sqb_raw_dc)" 2>/dev/null
	assert_contains "$(cat "$_SQB_STATE/sent" 2>/dev/null)" "👾 Carol(u9): hi" "discord→qqbot keeps 👾 + sender"
	. "$_HB/adapter/qqbot/message.sh"
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_attach_url_unescapes_amp() {
	# The webhook JSON carries '&' as \u0026 inside attachment URLs; sending it
	# raw made the CDN read one broken parameter pair → retcode -5503010.
	_it='{"content_type":"image/jpeg","url":"https://cdn.qq.com/a.jpg?appid=1407\u0026fileid=ABC\u0026rkey=R1"}'
	assert_eq "$(_qqbot_attach_url "$_it")" \
		"https://cdn.qq.com/a.jpg?appid=1407&fileid=ABC&rkey=R1" \
		"attachment url has \\u0026 decoded"
	_vit='{"content_type":"voice","url":"https://cdn.qq.com/v.silk","voice_wav_url":"https://cdn.qq.com/v.wav?a=1\u0026b=2"}'
	assert_eq "$(_qqbot_attach_url "$_vit")" "https://cdn.qq.com/v.wav?a=1&b=2" \
		"voice wav url has \\u0026 decoded"
}

test_sync_qqbot_bad_download_detected() {
	_bad="$_SQB_STATE/bad.json"
	printf '%s' '{"retcode":-5503010,"retmsg":"invalid rkey"}' > "$_bad"
	_qqbot_bad_download "$_bad"
	assert_ok "CDN error body detected"
	_good="$_SQB_STATE/good.jpg"
	printf '\377\330\377\340FAKEJPEGBYTES' > "$_good"
	_qqbot_bad_download "$_good"
	assert_fail "real jpeg not flagged"
	_big="$_SQB_STATE/big.json"
	{ printf '{"retmsg":"'; head -c 5000 /dev/zero | tr '\0' 'x'; printf '"}'; } > "$_big"
	_qqbot_bad_download "$_big"
	assert_fail "large json (>4KB) not treated as error body"
}

test_sync_qqbot_cdn_error_body_not_forwarded() {
	_sqb_conf 'qqbot/group/G1=telegram/-200'
	# Download succeeds at the transport level but the body is the CDN error.
	http_get_file() {
		mkdir -p "$(dirname "$2")" 2>/dev/null
		printf '%s' '{"retcode":-5503010,"retmsg":"invalid rkey"}' > "$2"
		return 0
	}
	mock_req_reset
	mock_set '{"ok":true,"result":{"message_id":99}}'
	_log="$(sync_handler "qqbot" "group_message" "MEM1" "[图片] a.png" "$(_sqb_raw_att)" 2>&1)"
	assert_contains "$_log" "CDN error body" "download logs the CDN error body"
	assert_not_contains "$(mock_last_req)" "sendPhoto" "error body is not uploaded as a photo"
	assert_not_contains "$(mock_last_req)" "sendDocument" "error body is not uploaded as a document"
	_sqb_restore_download
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

# ---- media kind regressions -------------------------------------------------
# The official bot API returns opaque, extension-less filenames, so a relayed
# picture used to reach Discord as a downloadable file (no preview) and could
# fall to sendDocument when content_type was missing.
_sqb_raw_att_noext() {
	printf '%s' '{"id":"MSG3","content":"pic","group_openid":"G1","author":{"id":"A1","member_openid":"MEM1"},"attachments":[{"content_type":"image/png","filename":"28F1A2B3","size":1234,"url":"https://cdn.example/x"}]}'
}

_sqb_raw_att_noct() {
	printf '%s' '{"id":"MSG4","content":"pic","group_openid":"G1","author":{"id":"A1","member_openid":"MEM1"},"attachments":[{"filename":"Q7W8E9","size":1234,"url":"https://cdn.example/y"}]}'
}

_sqb_stub_download_png() {
	http_get_file() {
		mkdir -p "$(dirname "$2")" 2>/dev/null
		printf '\211PNG\r\n\032\nFAKE' > "$2"
		return 0
	}
}

_sqb_capture_tg_upload() {
	: > "$_SQB_STATE/up-tg"
	_sync_tg_multipart() {
		printf 'method=%s field=%s fname=%s mime=%s\n' "$5" "$6" "$4" "$7" > "$_SQB_STATE/up-tg"
		return 0
	}
}

_sqb_capture_dc_upload() {
	: > "$_SQB_STATE/up-dc"
	_sync_dc_multipart() {
		printf 'fname=%s mime=%s\n' "$3" "$4" > "$_SQB_STATE/up-dc"
		return 0
	}
}

test_sync_qqbot_image_to_telegram_keeps_photo() {
	_sqb_conf 'qqbot/group/G1=telegram/-200'
	_sqb_stub_download
	_sqb_capture_tg_upload
	sync_handler "qqbot" "group_message" "MEM1" "[图片]" "$(_sqb_raw_att_noext)" 2>/dev/null
	assert_contains "$(cat "$_SQB_STATE/up-tg")" "method=sendPhoto" "extension-less png still goes out as sendPhoto"
	assert_contains "$(cat "$_SQB_STATE/up-tg")" "fname=28F1A2B3.png" "filename gets a .png suffix"
	assert_contains "$(cat "$_SQB_STATE/up-tg")" "mime=image/png" "mime stays image/png"
	_sqb_restore_download
	. ./plugin/sync/common.sh
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_image_to_discord_keeps_preview() {
	_sqb_conf 'qqbot/group/G1=discord/300'
	_sqb_stub_download
	_sqb_capture_dc_upload
	sync_handler "qqbot" "group_message" "MEM1" "[图片]" "$(_sqb_raw_att_noext)" 2>/dev/null
	assert_contains "$(cat "$_SQB_STATE/up-dc")" "fname=28F1A2B3.png" "discord upload keeps an image extension"
	assert_contains "$(cat "$_SQB_STATE/up-dc")" "mime=image/png" "discord upload keeps the image mime"
	_sqb_restore_download
	. ./plugin/sync/common.sh
	rm -f "$_SYNC_CONF"
}

test_sync_qqbot_image_sniffed_without_content_type() {
	_sqb_conf 'qqbot/group/G1=telegram/-200'
	_sqb_stub_download_png
	_sqb_capture_tg_upload
	sync_handler "qqbot" "group_message" "MEM1" "[图片]" "$(_sqb_raw_att_noct)" 2>/dev/null
	assert_contains "$(cat "$_SQB_STATE/up-tg")" "method=sendPhoto" "missing content_type is sniffed from PNG magic"
	assert_contains "$(cat "$_SQB_STATE/up-tg")" "fname=Q7W8E9.png" "sniffed type also fixes the filename"
	_sqb_restore_download
	. ./plugin/sync/common.sh
	rm -f "$_SYNC_CONF"
}

# ---- dc -> qqbot ------------------------------------------------------------
# dc-sync polls Discord itself and only knew qq/telegram targets, so messages
# seen by that poller never reached the QQ official bot.
_sqb_raw_dc_msg() {
	printf '%s' '{"id":"D7","content":"又能关掉一个无头ntqq，-800MB","channel_id":"300","author":{"id":"u9","username":"carol","global_name":"Carol"}}'
}

_sqb_raw_dc_att() {
	printf '%s' '{"id":"D8","content":"pic","channel_id":"300","author":{"id":"u9","username":"carol","global_name":"Carol"},"attachments":[{"id":"a1","filename":"9F8E7D","content_type":"image/png","url":"https://cdn.discordapp.com/attachments/1/2/9F8E7D"}]}'
}

test_sync_dc_to_qqbot_text() {
	_sqb_conf 'discord/300=qqbot/group/G2'
	_sqb_capture_group_send
	sync_dc_message "$(_sqb_raw_dc_msg)" "300" 2>/dev/null
	assert_contains "$(cat "$_SQB_STATE/sent")" "👾 Carol(u9): 又能关掉一个无头ntqq，-800MB" "dc→qqbot text keeps 👾 + sender"
	assert_eq "$(cat "$_STATE_DIR/msg-map-rev/300/D7" 2>/dev/null)" "qqbot G2 CAP1" "dc→qqbot rev-map"
	. "$_HB/adapter/qqbot/message.sh"
	rm -f "$_SYNC_CONF"
}

test_sync_dc_to_qqbot_image_is_media() {
	_sqb_conf 'discord/300=qqbot/group/G2'
	_sqb_stub_download
	: > "$_SQB_STATE/qb-up"
	qqbot_send_group_file_typed() {
		printf 'type=%s name=%s cap=%s\n' "$3" "$4" "$5" > "$_SQB_STATE/qb-up"
		return 0
	}
	sync_dc_message "$(_sqb_raw_dc_att)" "300" 2>/dev/null
	assert_contains "$(cat "$_SQB_STATE/qb-up")" "type=1" "dc image is uploaded as file_type=1 (image)"
	assert_contains "$(cat "$_SQB_STATE/qb-up")" "name=9F8E7D.png" "dc image keeps a .png name"
	assert_contains "$(cat "$_SQB_STATE/qb-up")" "👾 Carol(u9): [图片]" "dc image caption keeps 👾 + sender"
	. "$_HB/adapter/qqbot/message.sh"
	_sqb_restore_download
	rm -f "$_SYNC_CONF"
}

test_sync_dc_to_qqbot_loops_are_dropped() {
	_sqb_conf 'discord/300=qqbot/group/G2'
	_sqb_capture_group_send
	printf '%s' '{"id":"D9","content":"🅠 MEM1: hi","channel_id":"300","author":{"id":"u9","username":"carol","global_name":"Carol"}}' > /tmp/sqb-dc-loop-$$.json
	sync_dc_message "$(cat /tmp/sqb-dc-loop-$$.json)" "300" 2>/dev/null
	assert_eq "$(cat "$_SQB_STATE/sent" 2>/dev/null)" "" "dc→qqbot skips 🅠-prefixed relays (no loop)"
	. "$_HB/adapter/qqbot/message.sh"
	rm -f "$_SYNC_CONF" /tmp/sqb-dc-loop-$$.json
}

test_sync_sender_shows_short_ids() {
	assert_eq "$(_sync_get_sender qqbot '{"author":{"member_openid":"291A162D9F19B085571787A9E0F3C0B6"}}')" \
		"qq#291A162" "qqbot sender = qq# + first7 (no full openid)"
	assert_eq "$(_sync_get_sender discord '{"author":{"global_name":"Carol","id":"1364458119069175888"}}')" \
		"Carol(1364458)" "discord sender keeps nickname, id cut to 7"
	assert_eq "$(_sync_get_sender telegram '{"from":{"first_name":"Bob","id":123456789}}')" \
		"Bob(1234567)" "telegram sender without username cuts id to 7"
	assert_eq "$(_sync_get_sender telegram '{"from":{"first_name":"Bob","username":"bob"}}')" \
		"Bob(@bob)" "telegram @username left as-is"
	assert_eq "$(_sync_get_sender qq '{"sender_id":"123456789","group_member":{"nickname":"宝宝"}}')" \
		"宝宝(123456789)" "qq sender keeps full QQ number"
}

test_sync_qqbot_to_telegram
test_sync_qqbot_to_discord
test_sync_qqbot_to_qq_group
test_sync_qqbot_to_qqbot_group
test_sync_qqbot_to_qqbot_c2c
test_sync_qqbot_attach_url_unescapes_amp
test_sync_qqbot_bad_download_detected
test_sync_qqbot_cdn_error_body_not_forwarded
test_sync_sender_shows_short_ids
test_sync_telegram_to_qqbot_prefix
test_sync_discord_to_qqbot_prefix
test_sync_qqbot_image_to_telegram
test_sync_qqbot_image_to_discord
test_sync_qqbot_image_to_telegram_keeps_photo
test_sync_qqbot_image_to_discord_keeps_preview
test_sync_qqbot_image_sniffed_without_content_type
test_sync_dc_to_qqbot_text
test_sync_dc_to_qqbot_image_is_media
test_sync_dc_to_qqbot_loops_are_dropped
test_sync_qq_recall_to_qqbot
test_sync_qqbot_no_conf
test_sync_qqbot_loop_prefix

# restore for any later test file
_STATE_DIR="$_SQB_OLD_STATE"
test_purge "$_SQB_STATE"
