# adapter/qqbot/core.sh — QQ Bot OpenAPI v2 transport
#
# Independent from adapter/qq (Milky/LLOneBot): AppID+AppSecret auth,
# openid/group_openid ID space, HTTPS only, no local protocol endpoint.
# Source after lib/core.sh, lib/http.sh and etc/config.sh.
#
# All internal variables are prefixed _qb* — hush has no `local`, and
# hush-json/http.sh already own short names like _out/_json.

QQBOT_API_BASE="${QQBOT_API_BASE:-https://api.bot.qq.com}"
QQBOT_TOKEN_FILE="${QQBOT_TOKEN_FILE:-${_STATE_DIR:-$_HB/var/state}/qqbot-token.json}"
QQBOT_TOKEN_SKEW="${QQBOT_TOKEN_SKEW:-60}"      # refresh this many seconds early
QQBOT_ED25519_BIN="${QQBOT_ED25519_BIN:-$_HB/var/tools/ayu-ed25519}"
QQBOT_VERIFY_SIG="${QQBOT_VERIFY_SIG:-auto}"    # auto | 1 | 0

# qqbot_configured → 0 when AppID + AppSecret are present
qqbot_configured() {
	[ -n "${QQBOT_APP_ID:-}" ] && [ -n "${QQBOT_APP_SECRET:-}" ]
}

# ---- access_token cache -------------------------------------------------
# var/state/qqbot-token.json = {"access_token":"...","expires_at":<epoch>}
# The secret itself is never written; the token is 0600 in a 2750 dir.

qqbot_token_cached() {
	[ -f "$QQBOT_TOKEN_FILE" ] || return 1
	_qbc="$(cat "$QQBOT_TOKEN_FILE" 2>/dev/null)" || return 1
	_qbtok="$(json_get "$_qbc" access_token 2>/dev/null)" || return 1
	_qbexp="$(json_get "$_qbc" expires_at 2>/dev/null)" || return 1
	case "$_qbexp" in ''|*[!0-9]*) return 1 ;; esac
	[ -n "$_qbtok" ] || return 1
	[ "$_qbexp" -gt "$(( $(date +%s) + QQBOT_TOKEN_SKEW ))" ] || return 1
	printf '%s' "$_qbtok"
}

# qqbot_token_refresh → new token on stdout (cached on success)
qqbot_token_refresh() {
	qqbot_configured || {
		_ERROR="qqbot: QQBOT_APP_ID/QQBOT_APP_SECRET not configured"
		return 1
	}
	_qbf="/tmp/qqbot-token.$$"
	# appId must be a JSON *string*; json_obj would emit it unquoted (digits),
	# which the API rejects with {"code":100002,"message":"internal err"}.
	_qbbody="$(printf '{"appId":"%s","clientSecret":"%s"}' "$QQBOT_APP_ID" "$QQBOT_APP_SECRET")"
	http_post "$QQBOT_API_BASE/app/getAppAccessToken" \
		"$_qbbody" \
		"Content-Type: application/json" >"$_qbf" 2>/dev/null || {
			rm -f "$_qbf"
			_ERROR="qqbot.token: transport failed"
			return 1
		}
	_qbj="$(cat "$_qbf" 2>/dev/null)"
	rm -f "$_qbf"

	# failures carry {"code":N,"message":"..."} with HTTP 200
	_qbcode="$(json_get "$_qbj" code 2>/dev/null)" || _qbcode=""
	if [ -n "$_qbcode" ] && [ "$_qbcode" != "0" ]; then
		_ERROR="qqbot.token: code=$_qbcode msg=$(json_get "$_qbj" message 2>/dev/null)"
		return 1
	fi
	_qbtok="$(json_get "$_qbj" access_token 2>/dev/null)" || {
		_ERROR="qqbot.token: no access_token in response"
		return 1
	}
	_qbttl="$(json_get "$_qbj" expires_in 2>/dev/null)" || _qbttl="7200"
	case "$_qbttl" in ''|*[!0-9]*) _qbttl=7200 ;; esac

	_qbdir="$(dirname "$QQBOT_TOKEN_FILE")"
	mkdir -p "$_qbdir" 2>/dev/null
	chmod 750 "$_qbdir" 2>/dev/null
	if printf '{"access_token":"%s","expires_at":%s}' \
		"$_qbtok" "$(( $(date +%s) + _qbttl ))" >"$QQBOT_TOKEN_FILE.tmp.$$"; then
		chmod 600 "$QQBOT_TOKEN_FILE.tmp.$$" 2>/dev/null
		mv "$QQBOT_TOKEN_FILE.tmp.$$" "$QQBOT_TOKEN_FILE" 2>/dev/null || {
			rm -f "$QQBOT_TOKEN_FILE.tmp.$$"
			_ERROR="qqbot.token: cannot persist token"
			return 1
		}
	else
		rm -f "$QQBOT_TOKEN_FILE.tmp.$$"
		_ERROR="qqbot.token: cannot write token cache"
		return 1
	fi
	printf '%s' "$_qbtok"
}

qqbot_token() {
	qqbot_token_cached || qqbot_token_refresh
}

# ---- request core -------------------------------------------------------

# _qqbot_do <METHOD> <path> <body> → response body on stdout, _HTTP_STATUS set
_qqbot_do() {
	_qbm="$1" _qbp="$2" _qbb="$3"
	_qbtok="$(qqbot_token)" || return 1
	_qbauth="Authorization: QQBot $_qbtok"
	_qburl="$QQBOT_API_BASE$_qbp"
	case "$_qbm" in
		GET)    http_get    "$_qburl" "$_qbauth" ;;
		POST)   http_post   "$_qburl" "$_qbb" "Content-Type: application/json" "$_qbauth" ;;
		PUT)    http_put    "$_qburl" "$_qbb" "Content-Type: application/json" "$_qbauth" ;;
		PATCH)  http_patch  "$_qburl" "$_qbb" "Content-Type: application/json" "$_qbauth" ;;
		DELETE) http_delete "$_qburl" "$_qbb" "Content-Type: application/json" "$_qbauth" ;;
		*)      _ERROR="qqbot: unsupported method $_qbm"; return 1 ;;
	esac
}

# _qqbot_api <METHOD> <path> <body> <tag> → JSON on stdout, _ERROR on failure
# Rejects responses carrying a non-zero business `code` (QQ answers 200 even
# for auth/permission errors, so the HTTP status alone is not enough).
_qqbot_api() {
	_qam="$1" _qap="$2" _qab="$3" _qatag="$4"
	_qaf="/tmp/qqbot-api.$$"
	_qqbot_do "$_qam" "$_qap" "$_qab" >"$_qaf" 2>/dev/null
	_qarc=$?
	_qaj="$(cat "$_qaf" 2>/dev/null)"
	rm -f "$_qaf"
	if [ $_qarc -ne 0 ]; then
		_ERROR="$_qatag: transport failed (status ${_HTTP_STATUS:-none})"
		return 1
	fi
	_qac="$(json_get "$_qaj" code 2>/dev/null)" || _qac=""
	if [ -n "$_qac" ] && [ "$_qac" != "0" ]; then
		_qam2="$(json_get "$_qaj" message 2>/dev/null)" || _qam2=""
		_ERROR="$_qatag: code=$_qac msg=$_qam2 status=${_HTTP_STATUS:-none}"
		return 1
	fi
	printf '%s' "$_qaj"
}

# Drop the cached token (used on 401 from the platform)
qqbot_token_invalidate() {
	rm -f "$QQBOT_TOKEN_FILE" 2>/dev/null
	return 0
}

# __qqbot_urlenc <value> — percent-encode a path segment (openid is URL-safe,
# but message ids and cursors come from upstream JSON and must not be trusted)
qqbot_seg() {
	url_encode "$1"
}
