# test/test_qqbot.sh — QQ Bot (official) adapter tests
#
# Covered: op=13 callback validation vector, event ACK shape, dedup, signature
# enforcement, token cache, business-code rejection, message body builders.
# Every outbound call goes through the MOCK_HTTP layer, so nothing leaves the
# sandbox; no real AppID/Secret is required.

_QQBOT_TMP="$_HB/var/tmp-test-qqbot"
mkdir -p "$_QQBOT_TMP" 2>/dev/null
QQBOT_DEDUP_FILE="$_QQBOT_TMP/dedup"
QQBOT_TOKEN_FILE="$_QQBOT_TMP/token.json"
test_purge "$QQBOT_DEDUP_FILE" 2>/dev/null
test_purge "$QQBOT_TOKEN_FILE" 2>/dev/null

# --- configured detection ---

test_qqbot_configured_false() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET"
	QQBOT_APP_ID="" QQBOT_APP_SECRET=""
	qqbot_configured
	assert_fail "qqbot_configured false when empty"
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec"
}

test_qqbot_configured_true() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET"
	QQBOT_APP_ID="123456" QQBOT_APP_SECRET="secret"
	qqbot_configured
	assert_ok "qqbot_configured true when both set"
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec"
}

# --- op=13 callback url validation ---

test_qqbot_op13_vector() {
	# Official demo vector from the QQ Bot docs.
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET"
	QQBOT_APP_ID="1900000000" QQBOT_APP_SECRET="DG5g3B4j9X2KOErG"
	if ! qqbot_sign_bin_usable; then
		# helper not runnable in this image: nothing to verify here
		:
	else
		_body='{"op":13,"d":{"plain_token":"Arq0D5A61EgUu4OxUvOp","event_ts":"1725442341"}}'
		qqbot_webhook "$_body" >"$_QQBOT_TMP/out" 2>/dev/null
		_out="$(cat "$_QQBOT_TMP/out")"
		assert_contains "$_out" '"plain_token":"Arq0D5A61EgUu4OxUvOp"' "op13 echoes plain_token"
		_sig="$(printf '%s' "$_out" | sed -n 's/.*"signature":"\([0-9a-f]*\)".*/\1/p')"
		[ -n "$_sig" ] && _PASS=$((_PASS + 1)) || { _FAIL=$((_FAIL + 1)); printf 'FAIL: op13 signature missing\n'; }
		case "$_sig" in
			87befc99*) _PASS=$((_PASS + 1)) ;;
			*) _FAIL=$((_FAIL + 1)); printf 'FAIL: op13 signature prefix\n  got: %s\n' "$_sig" ;;
		esac
	fi
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec"
}

test_qqbot_op13_missing_fields() {
	_body='{"op":13,"d":{}}'
	qqbot_webhook "$_body" >/dev/null 2>&1
	assert_fail "op13 without plain_token fails"
	assert_eq "$_QQBOT_STATUS" "400 Bad Request" "op13 missing fields → 400"
}

test_qqbot_op13_without_secret() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET"
	QQBOT_APP_ID="" QQBOT_APP_SECRET=""
	_body='{"op":13,"d":{"plain_token":"abc","event_ts":"1"}}'
	qqbot_webhook "$_body" >/dev/null 2>&1
	assert_fail "op13 without credentials fails closed"
	assert_eq "$_QQBOT_STATUS" "500 Internal Server Error" "op13 no creds → 500"
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec"
}

# --- event ACK ---

test_qqbot_op13_ack_shape() {
	_body='{"op":0,"id":"EVT-1","t":"GROUP_AT_MESSAGE_CREATE","d":{"group_openid":"G1","id":"M1","content":"/ping","author":{"member_openid":"U1","bot":false},"timestamp":"2024-01-01T00:00:00Z"}}'
	qqbot_webhook "$_body" >"$_QQBOT_TMP/out" 2>/dev/null
	_out="$(cat "$_QQBOT_TMP/out")"
	assert_eq "$_out" '{"op":12,"d":{}}' "op0 answers HTTP-ACK body"
	assert_eq "$_QQBOT_STATUS" "200 OK" "op0 answers 200"
}

test_qqbot_op_unknown() {
	_body='{"op":7,"d":{}}'
	qqbot_webhook "$_body" >"$_QQBOT_TMP/out" 2>/dev/null
	_out="$(cat "$_QQBOT_TMP/out")"
	assert_eq "$_out" '{"op":12,"d":{}}' "unknown op still ACKs"
}

test_qqbot_empty_body() {
	qqbot_webhook "" >/dev/null 2>&1
	assert_fail "empty body rejected"
	assert_eq "$_QQBOT_STATUS" "400 Bad Request" "empty body → 400"
}

test_qqbot_event_without_t() {
	_body='{"op":0,"id":"EVT-NOT","d":{}}'
	qqbot_webhook "$_body" >"$_QQBOT_TMP/out" 2>/dev/null
	_out="$(cat "$_QQBOT_TMP/out")"
	assert_eq "$_out" '{"op":12,"d":{}}' "event without t is ACKed, not retried"
}

# --- dedup ---

test_qqbot_dedup() {
	test_purge "$QQBOT_DEDUP_FILE" 2>/dev/null
	qqbot_seen "EVT-DUP"
	assert_fail "unknown event id not seen"
	qqbot_remember "EVT-DUP"
	qqbot_seen "EVT-DUP"
	assert_ok "remembered event id is seen"
	qqbot_seen "evt-dup"
	assert_fail "dedup is case sensitive"
}

test_qqbot_dedup_prune() {
	test_purge "$QQBOT_DEDUP_FILE" 2>/dev/null
	_i=1
	while [ $_i -le 12 ]; do
		qqbot_remember "ID-$_i"
		_i=$((_i + 1))
	done
	_old="$QQBOT_DEDUP_MAX"
	QQBOT_DEDUP_MAX=5
	qqbot_remember "ID-13"
	_n="$(wc -l <"$QQBOT_DEDUP_FILE" | tr -d ' ')"
	assert_eq "$_n" "5" "dedup file pruned to max"
	qqbot_seen "ID-13"
	assert_ok "newest id survives pruning"
	qqbot_seen "ID-1"
	assert_fail "oldest id dropped by pruning"
	QQBOT_DEDUP_MAX="$_old"
}

# --- signature enforcement ---

test_qqbot_sig_required_without_headers() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET" _vsig="$QQBOT_VERIFY_SIG"
	QQBOT_APP_ID="123456" QQBOT_APP_SECRET="secret" QQBOT_VERIFY_SIG="1"
	if true; then
		_body='{"op":0,"id":"EVT-SIG","t":"C2C_MESSAGE_CREATE","d":{"author":{"user_openid":"U1"},"content":"hi","id":"M1"}}'
		qqbot_webhook "$_body" "" "" >/dev/null 2>&1
		assert_fail "unsigned callback rejected when verify=1"
		assert_eq "$_QQBOT_STATUS" "401 Unauthorized" "unsigned callback → 401"
	fi
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec" QQBOT_VERIFY_SIG="$_vsig"
}

test_qqbot_sig_disabled() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET" _vsig="$QQBOT_VERIFY_SIG"
	QQBOT_APP_ID="123456" QQBOT_APP_SECRET="secret" QQBOT_VERIFY_SIG="0"
	qqbot_signature_enabled
	assert_fail "verify=0 disables signature check"
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec" QQBOT_VERIFY_SIG="$_vsig"
}

# --- token cache ---

test_qqbot_token_refresh_and_cache() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET"
	test_purge "$QQBOT_TOKEN_FILE" 2>/dev/null
	QQBOT_APP_ID="123456" QQBOT_APP_SECRET="secret"
	mock_set '{"access_token":"tok-abc","expires_in":7200}'
	_t="$(qqbot_token_refresh)"
	assert_eq "$_t" "tok-abc" "token refresh returns access_token"
	[ -f "$QQBOT_TOKEN_FILE" ]
	assert_ok "token cache written"
	# a stale mock must not be used once the cache is warm
	mock_set '{"access_token":"tok-other","expires_in":7200}'
	_t2="$(qqbot_token)"
	assert_eq "$_t2" "tok-abc" "cached token reused while valid"
	test_purge "$QQBOT_TOKEN_FILE" 2>/dev/null
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec"
}

test_qqbot_token_business_error() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET"
	QQBOT_APP_ID="123456" QQBOT_APP_SECRET="bad"
	mock_set '{"code":100016,"message":"invalid appid or secret"}'
	qqbot_token_refresh >/dev/null 2>&1
	assert_fail "token refresh rejects business error"
	mock_set '{}'
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec"
}

# --- api layer ---

test_qqbot_api_business_code() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET"
	test_purge "$QQBOT_TOKEN_FILE" 2>/dev/null
	QQBOT_APP_ID="123456" QQBOT_APP_SECRET="secret"
	mock_set '{"access_token":"tok","expires_in":7200}'
	qqbot_token_refresh >/dev/null 2>&1
	mock_set '{"code":304003,"message":"param invalid"}'
	_qqbot_api POST "/v2/users/U1/messages" '{}' "qqbot.test"
	assert_fail "non-zero business code treated as failure"
	mock_set '{"id":"m1","timestamp":"2024-01-01T00:00:00Z"}'
	_out="$(_qqbot_api POST "/v2/users/U1/messages" '{}' "qqbot.test")"
	assert_eq "$_out" '{"id":"m1","timestamp":"2024-01-01T00:00:00Z"}' "api returns body on success"
	test_purge "$QQBOT_TOKEN_FILE" 2>/dev/null
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec"
}

test_qqbot_api_transport_fail() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET"
	QQBOT_APP_ID="123456" QQBOT_APP_SECRET="secret"
	mock_set '{"access_token":"tok","expires_in":7200}'
	qqbot_token_refresh >/dev/null 2>&1
	mock_fail 1
	_qqbot_api GET "/users/@me" "" "qqbot.test"
	assert_fail "transport failure propagates"
	mock_set '{}'
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec"
}

# --- message bodies ---

test_qqbot_body_text() {
	_b="$(qqbot_body_text "hello" "MSG-1" 2)"
	assert_contains "$_b" '"msg_type":0' "text body msg_type"
	assert_contains "$_b" '"content":"hello"' "text body content"
	assert_contains "$_b" '"msg_id":"MSG-1"' "text body msg_id"
	assert_contains "$_b" '"msg_seq":2' "text body msg_seq"
}

test_qqbot_body_markdown() {
	_b="$(qqbot_body_markdown "# hi" "MSG-2" 1)"
	assert_contains "$_b" '"markdown":{"content":"# hi"}' "markdown body carries content inside markdown"
	assert_contains "$_b" '"msg_type":2' "markdown body msg_type"
	assert_contains "$_b" '"msg_id":"MSG-2"' "markdown body msg_id"
}

test_qqbot_seg_encode() {
	_r="$(qqbot_seg 'a/b c')"
	assert_eq "$_r" "a%2Fb%20c" "path segment percent-encoded"
}

# --- handler replies ---

test_qqbot_handler_echo_strip() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET"
	test_purge "$QQBOT_TOKEN_FILE" 2>/dev/null
	QQBOT_APP_ID="123456" QQBOT_APP_SECRET="secret"
	mock_set '{"access_token":"tok","expires_in":7200}'
	qqbot_token_refresh >/dev/null 2>&1
	mock_set '{"id":"m2"}'
	_d='{"group_openid":"G1","id":"M1","content":"/echo hi there","author":{"member_openid":"U1"}}'
	qqbot_handler_echo qqbot group_message U1 "/echo hi there" "$_d"
	assert_ok "echo handler replies successfully"
	test_purge "$QQBOT_TOKEN_FILE" 2>/dev/null
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec"
}

test_qqbot_handler_no_target() {
	_oid="$QQBOT_APP_ID" _osec="$QQBOT_APP_SECRET"
	QQBOT_APP_ID="123456" QQBOT_APP_SECRET="secret"
	qqbot_reply_event '{"id":"M1"}' "x" 2>/dev/null
	assert_fail "reply without scene target fails"
	QQBOT_APP_ID="$_oid" QQBOT_APP_SECRET="$_osec"
}

# --- run ---
test_qqbot_configured_false
test_qqbot_configured_true
test_qqbot_op13_vector
test_qqbot_op13_missing_fields
test_qqbot_op13_without_secret
test_qqbot_op13_ack_shape
test_qqbot_op_unknown
test_qqbot_empty_body
test_qqbot_event_without_t
test_qqbot_dedup
test_qqbot_dedup_prune
test_qqbot_sig_required_without_headers
test_qqbot_sig_disabled
test_qqbot_token_refresh_and_cache
test_qqbot_token_business_error
test_qqbot_api_business_code
test_qqbot_api_transport_fail
test_qqbot_body_text
test_qqbot_body_markdown
test_qqbot_seg_encode
test_qqbot_handler_echo_strip
test_qqbot_handler_no_target
