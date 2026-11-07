# mock/mock_http.sh — mock http for testing (nc + ssl_client replacement)
# Source this AFTER core.sh but BEFORE the module under test.
# Works with lib/http.sh which checks MOCK_HTTP=1 at _http_raw entry.

MOCK_HTTP=1
MOCK_RESPONSE=""
MOCK_FAIL=0
MOCK_STATUS=1
MOCK_HTTP_STATUS=200

# mock_set <json> — set the mock response for the next http call
mock_set() {
	MOCK_RESPONSE="$1"
	MOCK_FAIL=0
}

# mock_fail [code] — make next http call fail
mock_fail() {
	MOCK_FAIL=1
	MOCK_STATUS="${1:-1}"
	MOCK_RESPONSE=""
}

# ---- request capture ---------------------------------------------------
# lib/http.sh records every outbound request (method, url, header lines) into
# MOCK_LOG while MOCK_HTTP=1 — see the mock branch in _http_raw. Header lines
# are captured exactly as they would go on the wire, so tests can assert on
# auth headers. Bodies are not recorded (base64 media would bloat the log).
# Capture lives in lib/http.sh rather than an overridden _http_raw here
# because adapter modules re-source lib/http.sh and would undo an override.

MOCK_LOG="${MOCK_LOG:-/tmp/ayu-mock-req.$$}"

# mock_req_reset — clear the capture log
mock_req_reset() { : > "$MOCK_LOG"; }

# mock_req_count — number of captured requests
mock_req_count() {
	[ -f "$MOCK_LOG" ] || { printf '0'; return 0; }
	grep -c '^=== REQ ' "$MOCK_LOG"
}

# mock_last_req — full text of the most recent captured request
mock_last_req() {
	[ -f "$MOCK_LOG" ] || return 0
	awk '/^=== REQ /{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$MOCK_LOG"
}

# mock_last_url — url of the most recent captured request
mock_last_url() {
	mock_last_req | sed -n '1s/^=== REQ [A-Z]* //p'
}

# mock_last_method — method of the most recent captured request
mock_last_method() {
	mock_last_req | sed -n '1s/^=== REQ \([A-Z]*\) .*/\1/p'
}

# mock_hdr_count <value-prefix> — how many header lines in the last request
# start with the given prefix (e.g. "X-Ayu-Token:", "X-Ayu-Token: abc")
mock_hdr_count() {
	mock_last_req | grep -c "^HDR $1"
}

# mock_header_lines — all header lines of the last request, without "HDR " prefix
mock_header_lines() {
	mock_last_req | sed -n 's/^HDR //p'
}

# mock_req_by_url <substring> — text of the last request whose url matches
mock_req_by_url() {
	awk -v pat="$1" '
		/^=== REQ /{ if (hit) last = buf; buf = $0 "\n"; hit = (index($0, pat) > 0); next }
		{ buf = buf $0 "\n" }
		END { if (hit) last = buf; printf "%s", last }
	' "$MOCK_LOG"
}

# mock_url_hdr_count <url-substring> <header-prefix>
mock_url_hdr_count() {
	mock_req_by_url "$1" | grep -c "^HDR $2"
}
