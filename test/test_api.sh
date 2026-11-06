# test/test_api.sh — webui JSON API contract

_api_req() {
    # $1 = query string; prints response body with headers stripped.
    # The shared secret is taken from etc/config.sh when present, so the suite
    # behaves the same on a dev checkout and on a configured production tree.
    ( cd "$(dirname "$0")/.." && _HB="$(pwd)" QUERY_STRING="$1" sh ./cgi-bin/api.sh 2>/dev/null | tr -d '\r' | sed -e '1,/^$/d' )
}

_api_secret() {
    ( cd "$(dirname "$0")/.." && sh -c '. ./etc/config.sh >/dev/null 2>&1; printf "%s" "${WEBHOOK_SECRET:-}"' )
}

_tok() {
    [ -n "${_SEC:-}" ] && printf '&token=%s' "$_SEC"
    return 0
}

test_api_status_json() {
    _out="$(_api_req "action=status$(_tok)")"
    assert_contains "$_out" '"port":' "status exposes port"
    assert_contains "$_out" '"platforms":' "status exposes platforms"
    assert_contains "$_out" '"state":{"msg_map":' "status exposes state counts"
    assert_not_contains "$_out" 'undefined' "no undefined placeholders"
}

test_api_config_hides_secrets() {
    _out="$(_api_req "action=config$(_tok)")"
    assert_contains "$_out" '"bot_port":' "config exposes port"
    assert_not_contains "$_out" "${TG_TOKEN:-__none__}" "config never returns bot token"
    assert_not_contains "$_out" "${WEBHOOK_SECRET:-__none__}" "config never returns webhook secret"
}

test_api_rejects_bad_token() {
    if [ -z "${_SEC:-}" ]; then
        # dev tree without a configured secret: no token is required at all
        _ok="$(_api_req 'action=status')"
        assert_contains "$_ok" '"port":' "status readable without secret"
        return 0
    fi
    _out="$(_api_req 'action=status&token=definitely-wrong')"
    assert_contains "$_out" '"error":"forbidden"' "bad token rejected"
    _ok="$(_api_req "action=status$(_tok)")"
    assert_contains "$_ok" '"port":' "good token accepted"
}

test_api_unknown_action() {
    _out="$(_api_req "action=nope$(_tok)")"
    assert_contains "$_out" '"error":"unknown action"' "unknown action rejected"
}

_SEC="$(_api_secret)"
test_api_status_json
test_api_config_hides_secrets
test_api_rejects_bad_token
test_api_unknown_action
