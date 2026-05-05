# Discord core — _dc_get, _dc_api, _dc_void
# Auth: Authorization: Bot <TOKEN>

. "$_HB/lib/http.sh"

# Pre-compute auth headers (CF WAF expects URL-encoded X-Ayu-Token)
if [ -n "${TG_API_SECRET:-}" ]; then
	_DC_AYU_AUTH="X-Ayu-Token: $(url_encode "${TG_API_SECRET}")"
fi

_dc_auth() {
    printf 'Authorization: Bot %s' "$DC_TOKEN"
}

# _dc_get <path> — GET request
_dc_get() {
    _path="$1"
    _out="/tmp/dc-out.$$"
    http_get "${DC_API_BASE}${_path}" \
        "$_CT_JSON" \
        "$(_dc_auth)" \
        "${_DC_AYU_AUTH:-}" >"$_out" || {
        _ERROR="dc.GET $_path: $_ERROR"
        rm -f "$_out"
        return 1
    }
    cat "$_out"
    rm -f "$_out"
}

# _dc_api <method> <path> <body> — POST/PATCH/PUT
_dc_api() {
    _m="$1" _p="$2" _body="$3"
    _out="/tmp/dc-out.$$"
    printf '%s' "$_body" > "$_out"
    _http_raw "$_m" "${DC_API_BASE}${_p}" "$_out" \
        "$_CT_JSON" \
        "$(_dc_auth)" \
        "${_DC_AYU_AUTH:-}" >"/tmp/dc-api-resp.$$" || {
        _ERROR="dc.$_m $_p: $_ERROR"
        rm -f "$_out" "/tmp/dc-api-resp.$$"
        return 1
    }
    cat "/tmp/dc-api-resp.$$"
    rm -f "$_out" "/tmp/dc-api-resp.$$"
}

# _dc_void <method> <path> [body] — fire-and-forget
_dc_void() {
    _m="$1" _p="$2"
    _body="${3:-{}}"
    _out="/tmp/dc-out.$$"
    printf '%s' "$_body" > "$_out"
    _http_raw "$_m" "${DC_API_BASE}${_p}" "$_out" \
        "$_CT_JSON" \
        "$(_dc_auth)" \
        "${_DC_AYU_AUTH:-}" >/dev/null || {
        _ERROR="dc.$_m $_p: $_ERROR"
        rm -f "$_out"
        return 1
    }
    rm -f "$_out"
}
