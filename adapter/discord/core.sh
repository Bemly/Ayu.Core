# Discord core — _dc_get, _dc_api, _dc_void
# Auth: Authorization: Bot <TOKEN>

. "$_HB/lib/http.sh"

_dc_auth() {
    printf 'Authorization: Bot %s' "$DC_TOKEN"
}

# _dc_get <path> — GET request
_dc_get() {
    _path="$1"
    _out="/tmp/dc-out.$$"
    http_get "${DC_API_BASE}${_path}" \
        "Content-Type: application/json" \
        "$(_dc_auth)" >"$_out" || {
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
    http_post "${DC_API_BASE}${_p}" "$_body" \
        "Content-Type: application/json" \
        "$(_dc_auth)" >"$_out" || {
        _ERROR="dc.$_m $_p: $_ERROR"
        rm -f "$_out"
        return 1
    }
    cat "$_out"
    rm -f "$_out"
}

# _dc_void <method> <path> — fire-and-forget (no body needed, or empty JSON)
_dc_void() {
    _m="$1" _p="$2"
    _body="${3:-{}}"
    _out="/tmp/dc-out.$$"
    http_post "${DC_API_BASE}${_p}" "$_body" \
        "Content-Type: application/json" \
        "$(_dc_auth)" >"$_out" || {
        _ERROR="dc.$_m $_p: $_ERROR"
        rm -f "$_out"
        return 1
    }
    rm -f "$_out"
}

# Execute webhook — POST /webhooks/{id}/{token} (no Bot auth)
dc_webhook_execute() {
    _url="https://discord.com/api/webhooks/$1/$2"
    _body="$(json_obj "content" "$3")"
    [ -n "${4:-}" ] && _body="$(printf '%s' "$_body" | sed 's/}$/,"username":"'"$4"'"/}')"
    http_post "$_url" "$_body" "Content-Type: application/json" || {
        _ERROR="dc.webhook_execute: $_ERROR"
        return 1
    }
}
