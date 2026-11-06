# test/test_router_auth.sh — router.sh end-to-end auth: QQBOT_WEBHOOK_TOKEN
# must unlock ONLY the qqbot endpoint (it travels in a URL the QQ platform
# stores and rewrites, so it must never act as a global webhook secret).

# _router_status <path> <query> → first response line from router.sh
_router_status() {
	printf '' | env -i \
		REQUEST_METHOD=POST \
		REQUEST_URI="$1?$2" \
		QUERY_STRING="$2" \
		CONTENT_LENGTH=0 \
		WEBHOOK_SECRET=realsecret \
		QQBOT_WEBHOOK_TOKEN=qqonly \
		PATH=/usr/bin:/bin \
		sh ./cgi-bin/router.sh 2>/dev/null | head -1 | tr -d '\r'
}

test_router_qqbot_token_on_qqbot_endpoint() {
	_out="$(_router_status /cgi-bin/router.sh/qqbot token=qqonly)"
	case "$_out" in
		*403*) assert_fail "qqbot endpoint rejected its own alt token: $_out" ;;
		*) assert_ok "qqbot endpoint accepts QQBOT_WEBHOOK_TOKEN" ;;
	esac
}

test_router_qqbot_token_blocked_on_qq() {
	_out="$(_router_status /cgi-bin/router.sh/qq token=qqonly)"
	assert_eq "$_out" 'Status: 403 Forbidden' "qqbot alt token must not unlock /qq"
}

test_router_qqbot_token_blocked_on_telegram() {
	_out="$(_router_status /cgi-bin/router.sh/telegram token=qqonly)"
	assert_eq "$_out" 'Status: 403 Forbidden' "qqbot alt token must not unlock /telegram"
}

test_router_wrong_token_blocked_everywhere() {
	_out="$(_router_status /cgi-bin/router.sh/qqbot token=wrongtok)"
	assert_eq "$_out" 'Status: 403 Forbidden' "unknown token rejected on /qqbot"
}

test_router_qqbot_token_on_qqbot_endpoint
test_router_qqbot_token_blocked_on_qq
test_router_qqbot_token_blocked_on_telegram
test_router_wrong_token_blocked_everywhere
