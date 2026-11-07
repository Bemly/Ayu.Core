# test/test_headers.sh — outbound auth header coverage for every call site
#
# Rule: no real credentials in tests. The production TG_API_SECRET / tokens
# are copied into shell variables kept only in memory, replaced by synthetic
# dummies, and restored before this file returns. Base URLs point at
# .invalid hosts, so even with MOCK_HTTP accidentally off nothing can reach a
# live API. Assertion output only ever shows the dummy values.

# Sourcing the sync modules lazily loads adapter/qqbot/core.sh and sets
# _QQBOT_SEND_LOADED. That flag suppresses every later reload, so a stubbed
# _qqbot_api from another test file would survive into test_sync_qqbot.
# Restore the pre-source state right away (and again after this file runs).
if [ -n "${_QQBOT_SEND_LOADED:-}" ]; then _HS0_QB_SET=1; _HS0_QB_VAL="$_QQBOT_SEND_LOADED"
else _HS0_QB_SET=0; _HS0_QB_VAL=""; fi

. ./plugin/sync/common.sh
. ./plugin/sync/from_dc.sh
. ./plugin/sync/from_qqbot.sh
. ./plugin/sync/from_tg.sh

if [ "$_HS0_QB_SET" = "1" ]; then _QQBOT_SEND_LOADED="$_HS0_QB_VAL"; else unset _QQBOT_SEND_LOADED; fi

_FAKE_SECRET='tst-s3cr3t+/=9'          # +, / and = force url_encode() to work
_FAKE_SECRET_ENC='tst-s3cr3t%2B%2F%3D9' # literal expectation for the encoder
_FAKE_TG_TOKEN='FAKE-TG-TOKEN'
_FAKE_DC_TOKEN='FAKE-DC-TOKEN'
_FAKE_QQ_TOKEN='FAKE-QQ-TOKEN'
_FAKE_QQBOT_TOKEN='FAKE-QQBOT-ACCESS-TOKEN'
_FAKE_QQBOT_SECRET='FAKE-QQBOT-SECRET'

# ---- fake environment ---------------------------------------------------

_hdr_setup_fake_env() {
	# keep the real values (memory only, never printed, never written)
	_HS_TG_SECRET="$TG_API_SECRET"
	_HS_TG_AUTH="$_TG_AUTH"
	_HS_DC_AUTH="${_DC_AYU_AUTH:-}"
	_HS_TG_BASE="$TG_API_BASE"
	_HS_TG_HOST="$TG_API_HOST"
	_HS_DC_BASE="$DC_API_BASE"
	_HS_DC_PROXY="${DC_CDN_PROXY:-}"
	_HS_QQ_BASE="$QQ_API_BASE"
	_HS_QQBOT_BASE="$QQBOT_API_BASE"
	_HS_TOKEN_FILE="$QQBOT_TOKEN_FILE"
	_HS_TGTOKEN="$TG_TOKEN"
	_HS_DCTOKEN="$DC_TOKEN"
	_HS_QQTOKEN="$QQ_TOKEN"
	_HS_QQBOT_ID="$QQBOT_APP_ID"
	_HS_QQBOT_SECRET="$QQBOT_APP_SECRET"
	_HS_SYNC_CONF="${_SYNC_CONF:-}"
	# from_qqbot.sh only pulls adapter/qqbot/core.sh in once (_QQBOT_SEND_LOADED).
	# Sourcing it here would make later files keep a stubbed _qqbot_api, so the
	# flag is put back exactly as found.
	if [ -n "${_QQBOT_SEND_LOADED:-}" ]; then
		_HS_QB_SEND_SET=1
		_HS_QB_SEND_VAL="$_QQBOT_SEND_LOADED"
	else
		_HS_QB_SEND_SET=0
		_HS_QB_SEND_VAL=""
	fi

	TG_API_SECRET="$_FAKE_SECRET"
	TG_TOKEN="$_FAKE_TG_TOKEN"
	DC_TOKEN="$_FAKE_DC_TOKEN"
	QQ_TOKEN="$_FAKE_QQ_TOKEN"
	QQBOT_APP_ID="fake-app-id"
	QQBOT_APP_SECRET="$_FAKE_QQBOT_SECRET"

	TG_API_BASE="https://tg.invalid/bot${_FAKE_TG_TOKEN}"
	TG_API_HOST="tg.invalid"
	DC_API_BASE="https://dc.invalid/api/v10"
	QQ_API_BASE="http://qq.invalid"
	QQBOT_API_BASE="https://qqbot.invalid"
	# never touch the production token cache
	QQBOT_TOKEN_FILE="/tmp/ayu-test-qqbot-token.$$"
	DC_CDN_PROXY=""

	# recompute the pre-computed auth headers from the dummy secret
	_TG_AUTH="X-Ayu-Token: $(url_encode "$_FAKE_SECRET")"
	_DC_AYU_AUTH="X-Ayu-Token: $(url_encode "$_FAKE_SECRET")"
}

_hdr_restore_env() {
	TG_API_SECRET="$_HS_TG_SECRET"
	_TG_AUTH="$_HS_TG_AUTH"
	_DC_AYU_AUTH="$_HS_DC_AUTH"
	TG_API_BASE="$_HS_TG_BASE"
	TG_API_HOST="$_HS_TG_HOST"
	DC_API_BASE="$_HS_DC_BASE"
	DC_CDN_PROXY="$_HS_DC_PROXY"
	QQ_API_BASE="$_HS_QQ_BASE"
	QQBOT_API_BASE="$_HS_QQBOT_BASE"
	QQBOT_TOKEN_FILE="$_HS_TOKEN_FILE"
	TG_TOKEN="$_HS_TGTOKEN"
	DC_TOKEN="$_HS_DCTOKEN"
	QQ_TOKEN="$_HS_QQTOKEN"
	QQBOT_APP_ID="$_HS_QQBOT_ID"
	QQBOT_APP_SECRET="$_HS_QQBOT_SECRET"
	_SYNC_CONF="$_HS_SYNC_CONF"
	if [ "$_HS_QB_SEND_SET" = "1" ]; then
		_QQBOT_SEND_LOADED="$_HS_QB_SEND_VAL"
	else
		unset _QQBOT_SEND_LOADED
	fi
	rm -f "/tmp/ayu-test-qqbot-token.$$"
}

# ---- assertion helpers --------------------------------------------------

# assert_ayu_hdr <msg> — last request carries exactly one correct X-Ayu-Token
assert_ayu_hdr() {
	assert_eq "$(mock_hdr_count 'X-Ayu-Token: ')" "1" "$1: X-Ayu-Token present once"
	assert_eq "$(mock_hdr_count "X-Ayu-Token: $_FAKE_SECRET_ENC")" "1" \
		"$1: X-Ayu-Token value (urlencoded)"
	assert_eq "$(mock_hdr_count 'X-Ayu-Token: ')" \
		"$(mock_hdr_count "X-Ayu-Token: $_FAKE_SECRET_ENC")" \
		"$1: no malformed X-Ayu-Token line"
}

# assert_ayu_hdr_all <msg> — every request captured so far carries it
assert_ayu_hdr_all() {
	_n="$(mock_req_count)"
	_h="$(grep -c '^HDR X-Ayu-Token: ' "$MOCK_LOG" 2>/dev/null)"
	_e="$(grep -c "^HDR X-Ayu-Token: $_FAKE_SECRET_ENC\$" "$MOCK_LOG" 2>/dev/null)"
	assert_eq "$_h" "$_n" "$1: X-Ayu-Token on all $_n requests"
	assert_eq "$_e" "$_n" "$1: correct encoded value on all $_n requests"
}

# assert_header_exact <msg> <full header line>
assert_header_exact() {
	assert_eq "$(mock_hdr_count "$2")" "1" "$1: header [$2]"
}

# _hdr_tmpfile — scratch payload for multipart uploads
_hdr_tmpfile() {
	_f="/tmp/ayu-hdr-payload.$$"
	printf 'payload-bytes' > "$_f"
	printf '%s' "$_f"
}

# ---- Telegram ----------------------------------------------------------

test_hdr_tg_text_send() {
	mock_req_reset
	mock_set '{"ok":true,"result":{"message_id":1}}'
	tg_sendMessage "12345" "hello" >/dev/null 2>&1
	assert_eq "$(mock_last_method)" "POST" "tg text: method"
	assert_contains "$(mock_last_url)" "/sendMessage" "tg text: endpoint"
	assert_ayu_hdr "tg text"
}

# every multipart method the sync plugin can pick must carry the header
test_hdr_tg_multipart_methods() {
	_f="$(_hdr_tmpfile)"
	for _m in sendPhoto sendDocument sendAnimation sendVideo sendVoice sendAudio; do
		mock_req_reset
		mock_set '{"ok":true,"result":{"message_id":2}}'
		_sync_tg_multipart "-200" "" "$_f" "a.bin" "$_m" "document" \
			"application/octet-stream" "cap" >/dev/null 2>&1
		assert_eq "$(mock_last_method)" "POST" "tg multipart $_m: method"
		assert_contains "$(mock_last_url)" "/$_m" "tg multipart $_m: endpoint"
		assert_ayu_hdr "tg multipart $_m"
	done
	rm -f "$_f"
}

test_hdr_tg_download() {
	_f="$(_hdr_tmpfile)"
	mock_req_reset
	mock_set '{"ok":true,"result":{"file_path":"photos/file_1.jpg"}}'
	# first request = getFile (JSON api), second = the CDN file fetch
	_tg_download_file "file-id" "t" "hdr" >/dev/null 2>&1
	assert_eq "$(mock_req_count)" "2" "tg download: two requests (getFile + fetch)"
	assert_ayu_hdr_all "tg download"
	rm -f "$_f" "/tmp/img/sync-t-tg-$$-"* 2>/dev/null
}

# ---- Discord -----------------------------------------------------------

test_hdr_dc_get() {
	mock_req_reset
	mock_set '{"id":"m1"}'
	dc_message_get "c1" "m1" >/dev/null 2>&1
	assert_eq "$(mock_last_method)" "GET" "dc get: method"
	assert_header_exact "dc get" "Authorization: Bot $_FAKE_DC_TOKEN"
	assert_ayu_hdr "dc get"
}

test_hdr_dc_post() {
	mock_req_reset
	mock_set '{"id":"m2"}'
	dc_message_create "c1" '{"content":"x"}' >/dev/null 2>&1
	assert_eq "$(mock_last_method)" "POST" "dc post: method"
	assert_ayu_hdr "dc post"
}

test_hdr_dc_patch() {
	mock_req_reset
	mock_set '{"id":"m3"}'
	dc_message_edit "c1" "m3" '{"content":"y"}' >/dev/null 2>&1
	assert_eq "$(mock_last_method)" "PATCH" "dc patch: method"
	assert_ayu_hdr "dc patch"
}

test_hdr_dc_delete() {
	mock_req_reset
	mock_set '{}'
	dc_message_delete "c1" "m4" >/dev/null 2>&1
	assert_eq "$(mock_last_method)" "DELETE" "dc delete: method"
	assert_ayu_hdr "dc delete"
}

test_hdr_dc_webhook() {
	mock_req_reset
	mock_set '{}'
	dc_webhook_execute "w1" "wtok" "hi" >/dev/null 2>&1
	assert_contains "$(mock_last_url)" "/api/webhooks/w1/wtok" "dc webhook: url"
	assert_ayu_hdr "dc webhook"
}

test_hdr_dc_multipart() {
	_f="$(_hdr_tmpfile)"
	mock_req_reset
	mock_set '{"id":"m5"}'
	_sync_dc_multipart "c1" "$_f" "a.png" "image/png" "cap" >/dev/null 2>&1
	assert_contains "$(mock_last_url)" "/channels/c1/messages" "dc multipart: url"
	assert_header_exact "dc multipart" "Authorization: Bot $_FAKE_DC_TOKEN"
	assert_ayu_hdr "dc multipart"
	rm -f "$_f"
}

# ---- Discord CDN fetches through the proxy (from_dc.sh) ----------------

_hdr_dc_raw() {
	printf '%s' '{"id":"9","content":"","author":{"id":"999999"},"attachments":[{"url":"https://cdn.discordapp.com/attachments/1/2/a.png","filename":"a.png","content_type":"image/png"}]}'
}

_hdr_set_conf() {
	_SYNC_CONF="/tmp/ayu-hdr-sync-$$.conf"
	printf '%s\n' "$1" > "$_SYNC_CONF"
	mkdir -p /tmp/img 2>/dev/null
}

test_hdr_dc_cdn_download_to_qq() {
	_hdr_set_conf "discord/123=qq/group/100"
	mkdir -p /tmp/img 2>/dev/null
	mock_req_reset
	mock_set '{"status":"ok","retcode":0,"data":{}}'
	DC_CDN_PROXY="proxy.invalid" sync_dc_message "$(_hdr_dc_raw)" "123" >/dev/null 2>&1
	assert_eq "$(grep -c '^=== REQ [A-Z]* https://proxy.invalid/' "$MOCK_LOG")" "1" \
		"dc cdn→qq: download went through proxy"
	assert_eq "$(mock_url_hdr_count 'https://proxy.invalid/' "X-Ayu-Token: $_FAKE_SECRET_ENC")" "1" \
		"dc cdn→qq: download carries X-Ayu-Token"
	assert_eq "$(mock_url_hdr_count 'qq.invalid' 'X-Ayu-Token:')" "0" \
		"dc cdn→qq: QQ endpoint gets no Ayu header"
	rm -f "$_SYNC_CONF" /tmp/img/sync-dc-qq-$$-* 2>/dev/null
}

test_hdr_dc_cdn_download_to_tg() {
	_hdr_set_conf "discord/123=telegram/-200"
	mock_req_reset
	mock_set '{"ok":true,"result":{"message_id":3}}'
	DC_CDN_PROXY="proxy.invalid" sync_dc_message "$(_hdr_dc_raw)" "123" >/dev/null 2>&1
	assert_eq "$(grep -c '^=== REQ [A-Z]* https://proxy.invalid/' "$MOCK_LOG")" "1" \
		"dc cdn→tg: download went through proxy"
	assert_ayu_hdr_all "dc cdn→tg"
	rm -f "$_SYNC_CONF" /tmp/img/sync-dc-tg-$$-* 2>/dev/null
}

test_hdr_dc_cdn_download_to_qqbot() {
	_hdr_set_conf "discord/123=qqbot/openid123"
	mock_req_reset
	# 1st call: getAppAccessToken, then the media upload
	mock_set '{"access_token":"'"$_FAKE_QQBOT_TOKEN"'","expires_in":7200}'
	DC_CDN_PROXY="proxy.invalid" sync_dc_message "$(_hdr_dc_raw)" "123" >/dev/null 2>&1
	assert_eq "$(grep -c '^=== REQ [A-Z]* https://proxy.invalid/' "$MOCK_LOG")" "1" \
		"dc cdn→qqbot: download went through proxy"
	assert_eq "$(mock_url_hdr_count 'https://proxy.invalid/' "X-Ayu-Token: $_FAKE_SECRET_ENC")" "1" \
		"dc cdn→qqbot: download carries X-Ayu-Token"
	assert_eq "$(mock_url_hdr_count 'qqbot.invalid' 'X-Ayu-Token:')" "0" \
		"dc cdn→qqbot: official API gets no Ayu header"
	rm -f "$_SYNC_CONF" /tmp/img/sync-dc-qqbot-$$-* 2>/dev/null
}

# without the proxy the CDN is fetched directly — no Ayu header may leak
test_hdr_dc_cdn_no_proxy_no_ayu_hdr() {
	_hdr_set_conf "discord/123=qq/group/100"
	mock_req_reset
	mock_set '{"status":"ok","retcode":0,"data":{}}'
	sync_dc_message "$(_hdr_dc_raw)" "123" >/dev/null 2>&1
	assert_eq "$(grep -c '^=== REQ [A-Z]* https://cdn.discordapp.com/' "$MOCK_LOG")" "1" \
		"dc cdn direct: hit cdn.discordapp.com"
	assert_eq "$(grep -c '^HDR X-Ayu-Token' "$MOCK_LOG")" "0" \
		"dc cdn direct: no X-Ayu-Token sent to Discord CDN"
	rm -f "$_SYNC_CONF" /tmp/img/sync-dc-qq-$$-* 2>/dev/null
}

# ---- QQ (LLOneBot) -----------------------------------------------------

test_hdr_qq_bearer() {
	mock_req_reset
	mock_set '{"status":"ok","retcode":0,"data":{}}'
	qq_message_send_group "100" '[{"type":"text","data":{"text":"x"}}]' >/dev/null 2>&1
	assert_header_exact "qq send" "Authorization: Bearer $_FAKE_QQ_TOKEN"
	assert_eq "$(mock_hdr_count 'X-Ayu-Token:')" "0" "qq send: no Ayu header to local endpoint"
}

# ---- QQ official bot (OpenAPI v2) --------------------------------------

test_hdr_qqbot_auth() {
	rm -f "$QQBOT_TOKEN_FILE"
	mock_req_reset
	mock_set '{"access_token":"'"$_FAKE_QQBOT_TOKEN"'","expires_in":7200}'
	qqbot_token_refresh >/dev/null 2>&1
	assert_ok "qqbot token refresh"

	mock_set '{"id":"1","username":"bot"}'
	_qqbot_api "GET" "/users/@me" "" "hdr" >/dev/null 2>&1
	assert_header_exact "qqbot api" "Authorization: QQBot $_FAKE_QQBOT_TOKEN"
	assert_eq "$(mock_hdr_count 'X-Ayu-Token:')" "0" "qqbot api: no Ayu header (direct API)"
	rm -f "$QQBOT_TOKEN_FILE"
}

test_hdr_qqbot_media_upload() {
	rm -f "$QQBOT_TOKEN_FILE"
	_f="$(_hdr_tmpfile)"
	mock_req_reset
	mock_set '{"access_token":"'"$_FAKE_QQBOT_TOKEN"'","expires_in":7200}'
	qqbot_token_refresh >/dev/null 2>&1

	mock_set '{"code":0,"data":{"file_uuid":"u1"}}'
	_qqbot_api_body "/v2/groups/1/files" "$_f" "hdr" >/dev/null 2>&1
	assert_eq "$(mock_last_method)" "POST" "qqbot upload: method"
	assert_header_exact "qqbot upload" "Authorization: QQBot $_FAKE_QQBOT_TOKEN"
	rm -f "$_f" "$QQBOT_TOKEN_FILE"
}

# ---- unset secret must not inject an empty header line -----------------

test_hdr_dc_unset_secret_no_blank_header() {
	_sv="$_DC_AYU_AUTH"
	_DC_AYU_AUTH=""
	mock_req_reset
	mock_set '{"id":"m6"}'
	dc_message_get "c1" "m6" >/dev/null 2>&1
	assert_eq "$(grep -c '^HDR $' "$MOCK_LOG")" "0" \
		"dc without secret: no empty header line"
	assert_header_exact "dc without secret" "Authorization: Bot $_FAKE_DC_TOKEN"
	_DC_AYU_AUTH="$_sv"
}

test_hdr_tg_unset_secret_no_blank_header() {
	_sv="$_TG_AUTH"
	_TG_AUTH=""
	mock_req_reset
	mock_set '{"ok":true,"result":{"message_id":7}}'
	# TG keeps a dedicated branch for the unset case
	TG_API_SECRET="" tg_sendMessage "1" "hi" >/dev/null 2>&1
	assert_eq "$(grep -c '^HDR $' "$MOCK_LOG")" "0" \
		"tg without secret: no empty header line"
	assert_eq "$(mock_hdr_count 'X-Ayu-Token:')" "0" \
		"tg without secret: no X-Ayu-Token"
	_TG_AUTH="$_sv"
}

# ---- run ---------------------------------------------------------------

_hdr_setup_fake_env

test_hdr_tg_text_send
test_hdr_tg_multipart_methods
test_hdr_tg_download
test_hdr_dc_get
test_hdr_dc_post
test_hdr_dc_patch
test_hdr_dc_delete
test_hdr_dc_webhook
test_hdr_dc_multipart
test_hdr_dc_cdn_download_to_qq
test_hdr_dc_cdn_download_to_tg
test_hdr_dc_cdn_download_to_qqbot
test_hdr_dc_cdn_no_proxy_no_ayu_hdr
test_hdr_qq_bearer
test_hdr_qqbot_auth
test_hdr_qqbot_media_upload
test_hdr_dc_unset_secret_no_blank_header
test_hdr_tg_unset_secret_no_blank_header

# Guard: the capture log must never have seen a production credential, in raw
# or url-encoded form. (Compared in memory; nothing is printed unless it fails.)
if [ -n "$_HS_TG_SECRET" ]; then
	assert_not_contains "$(cat "$MOCK_LOG")" "$_HS_TG_SECRET" \
		"capture log has no real TG_API_SECRET"
	assert_not_contains "$(cat "$MOCK_LOG")" "$(url_encode "$_HS_TG_SECRET")" \
		"capture log has no encoded real TG_API_SECRET"
fi
for _real in "$_HS_TGTOKEN" "$_HS_DCTOKEN" "$_HS_QQTOKEN" "$_HS_QQBOT_SECRET"; do
	[ -n "$_real" ] || continue
	assert_not_contains "$(cat "$MOCK_LOG")" "$_real" \
		"capture log has no real token/secret"
done

_hdr_restore_env
