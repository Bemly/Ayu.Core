# test/test_sync_tmpvars.sh — multipart helpers must not clobber caller scratch vars
#
# hush has no `local`. Historically _sync_tg_multipart/_sync_dc_multipart reused
# the caller's `_tmp` for their own multipart body. After the upload returned,
# the caller's `rm -f "$_tmp"` pointed at the helper's already-deleted
# /tmp/{tg,dc}-up-$$ file, so the downloaded media was never removed from
# /tmp/img and accumulated for months (12.7G by 2026-11-07).
#
# These tests pin the contract: helpers touch only their own _tgm_/_dcm_ names,
# and the caller is the one that deletes the downloaded file.

. ./plugin/sync/handler.sh

test_sync_tg_multipart_keeps_caller_vars() {
	_tmp="/tmp/img/sync-guard-tg-$$"
	_url="https://cdn.example/keep-me"
	mkdir -p /tmp/img 2>/dev/null
	printf 'payload' > "$_tmp"
	mock_set '{"ok":true,"result":{"message_id":1}}'
	_sync_tg_multipart "-200" "" "$_tmp" "f.txt" "sendDocument" "document" "text/plain" "cap" >/dev/null 2>&1
	assert_eq "$_tmp" "/tmp/img/sync-guard-tg-$$" "tg multipart leaves caller _tmp intact"
	assert_eq "$_url" "https://cdn.example/keep-me" "tg multipart leaves caller _url intact"
	assert_eq "$(cat "$_tmp" 2>/dev/null)" "payload" "caller file still present for caller to delete"
	rm -f "$_tmp"
}

test_sync_dc_multipart_keeps_caller_vars() {
	_tmp="/tmp/img/sync-guard-dc-$$"
	_cid="300"
	mkdir -p /tmp/img 2>/dev/null
	printf 'payload' > "$_tmp"
	mock_set '{"id":"m1"}'
	_sync_dc_multipart "$_cid" "$_tmp" "f.txt" "text/plain" "cap" >/dev/null 2>&1
	assert_eq "$_tmp" "/tmp/img/sync-guard-dc-$$" "dc multipart leaves caller _tmp intact"
	assert_eq "$_cid" "300" "dc multipart leaves caller _cid intact"
	assert_eq "$(cat "$_tmp" 2>/dev/null)" "payload" "caller file still present for caller to delete"
	rm -f "$_tmp"
}

# End-to-end: one QQ image forwarded to Discord must leave nothing in /tmp/img.
# The stubs live in a subshell so the real helpers stay untouched elsewhere.
test_sync_qq_image_to_dc_cleans_temp_file() {
	mkdir -p /tmp/img 2>/dev/null
	mock_set '{"id":"m1"}'
	_res="$(
		http_get_file() { printf 'GIF89a' > "$2"; printf '%s' "$2" > /tmp/ayu-guard-path; return 0; }
		_qq_extract_segments() { printf '%s\n' '{"type":"image","data":{"temp_url":"https://cdn.example/x.gif"}}'; }
		_sync_qq_images_to_dc '{}' '300' 'Alice' >/dev/null 2>&1
		_p="$(cat /tmp/ayu-guard-path 2>/dev/null)"
		if [ -n "$_p" ] && [ ! -f "$_p" ]; then
			printf 'cleaned'
		else
			printf 'left:%s' "$_p"
		fi
	)"
	assert_eq "$_res" "cleaned" "qq->dc image temp file removed after forward"
	rm -f /tmp/ayu-guard-path
}

test_sync_tg_multipart_keeps_caller_vars
test_sync_dc_multipart_keeps_caller_vars
test_sync_qq_image_to_dc_cleans_temp_file
