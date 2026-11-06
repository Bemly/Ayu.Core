# test/test_scrub.sh — credential redaction in log lines

test_scrub_query_token() {
    out="$(_log_scrub 'POST /cgi-bin/router.sh/qq?token=abc123&x=1')"
    assert_not_contains "$out" "abc123" "query token value masked"
    assert_contains "$out" "token=***" "query token replaced with ***"
}

test_scrub_json_secret() {
    out="$(_log_scrub '{"WEBHOOK_SECRET":"hunter2","chat_id":1}')"
    assert_not_contains "$out" "hunter2" "json secret masked"
    out2="$(_log_scrub '{"token":"hunter2"}')"
    assert_not_contains "$out2" "hunter2" "json lowercase token masked"
}

test_scrub_tg_bot_token() {
    out="$(_log_scrub 'https://api.telegram.org/bot123456789:AAH-qq_zz/sendMessage')"
    assert_not_contains "$out" "AAH-qq_zz" "bot token masked in URL"
    out2="$(_log_scrub 'Authorization: Bot 123456789:AAF-xyz')"
    assert_not_contains "$out2" "AAF-xyz" "Bot header token masked"
}

test_scrub_file_url() {
    out="$(_log_scrub 'https://api.telegram.org/file/bot123:AAE/voice/file_0.ogg')"
    assert_contains "$out" "file/bot***" "file url token masked"
    assert_not_contains "$out" "AAE" "file url token gone"
}

test_scrub_keeps_normal_text() {
    out="$(_log_scrub 'router: POST /cgi-bin/router.sh/qq platform=qq len=42')"
    assert_eq "$out" 'router: POST /cgi-bin/router.sh/qq platform=qq len=42' "plain line untouched"
}

test_scrub_query_token
test_scrub_json_secret
test_scrub_tg_bot_token
test_scrub_file_url
test_scrub_keeps_normal_text
