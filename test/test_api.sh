# test/test_api.sh — webui JSON API contract

_api_req() {
    # $1 = query string; prints response body with headers stripped
    ( cd "$(dirname "$0")/.." && _HB="$(pwd)" WEBHOOK_SECRET="${WEBHOOK_SECRET:-}" QUERY_STRING="$1" sh ./cgi-bin/api.sh 2>/dev/null | tr -d '\r' | sed -e '1,/^$/d' )
}

test_api_status_json() {
    _out="$(_api_req 'action=status')"
    assert_contains "$_out" '"port":' "status exposes port"
    assert_contains "$_out" '"platforms":' "status exposes platforms"
    assert_contains "$_out" '"state":{"msg_map":' "status exposes state counts"
    assert_not_contains "$_out" 'undefined' "no undefined placeholders"
}

test_api_config_hides_secrets() {
    _out="$(_api_req 'action=config')"
    assert_contains "$_out" '"bot_port":' "config exposes port"
    assert_not_contains "$_out" "${TG_TOKEN:-__none__}" "config never returns bot token"
    assert_not_contains "$_out" "${WEBHOOK_SECRET:-__none__}" "config never returns webhook secret"
}

test_api_rejects_bad_token() {
    _sec="$WEBHOOK_SECRET"
    WEBHOOK_SECRET="s3cret"
    _out="$(_api_req 'action=status&token=wrong')"
    assert_contains "$_out" '"error":"forbidden"' "bad token rejected"
    _ok="$(_api_req 'action=status&token=s3cret')"
    assert_contains "$_ok" '"port":' "good token accepted"
    WEBHOOK_SECRET="$_sec"
}

test_api_unknown_action() {
    _out="$(_api_req 'action=nope')"
    assert_contains "$_out" '"error":"unknown action"' "unknown action rejected"
}

test_api_status_json
test_api_config_hides_secrets
test_api_rejects_bad_token
test_api_unknown_action
