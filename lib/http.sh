# http.sh — HTTP/HTTPS via nc + ssl_client (no wget)
# Source after core.sh
# ALL internal variables prefixed _h* to avoid hush global var collisions

_HTTP_STATUS=""
_HTTP_RETRY="${_HTTP_RETRY:-2}"
_HTTP_TIMEOUT="${_HTTP_TIMEOUT:-10}"
_CT_JSON="Content-Type: application/json"

# ---- mock support (set by test/mock/mock_http.sh) ----
# MOCK_HTTP=1 → short-circuit, return MOCK_RESPONSE or fail

# _url_parse <url> → sets _hproto _hhost _hport _hpath
_url_parse() {
	_hurl="$1"
	_hproto="${_hurl%%://*}"
	_hrest="${_hurl#*://}"
	_hhost="${_hrest%%/*}"
	case "$_hhost" in
		*:*) _hport="${_hhost##*:}"; _hhost="${_hhost%:*}" ;;
		*) _hport="";;
	esac
	_hpath="/${_hrest#*/}"
	[ -z "$_hport" ] && {
		case "$_hproto" in
			https|wss) _hport=443 ;;
			*) _hport=80 ;;
		esac
	}
}

# _http_build_req <method> <path> <host> <body_file> [headers...]
# Writes full HTTP request to /tmp/ayu-req.$$.http
_http_build_req() {
	_hmethod="$1" _hrpath="$2" _hrhost="$3" _hbfile="$4"; shift 4
	_hreq="/tmp/ayu-req.$$.http"
	> "$_hreq"
	printf '%s %s HTTP/1.0\r\n' "$_hmethod" "$_hrpath" >> "$_hreq"
	printf 'Host: %s\r\n' "$_hrhost" >> "$_hreq"
	for _hdr in "$@"; do
		printf '%s\r\n' "$_hdr" >> "$_hreq"
	done
	printf 'Connection: close\r\n' >> "$_hreq"
	if [ -n "$_hbfile" ] && [ -s "$_hbfile" ]; then
		_hblen=$(wc -c < "$_hbfile")
		printf 'Content-Length: %d\r\n' "$_hblen" >> "$_hreq"
		printf '\r\n' >> "$_hreq"
		cat "$_hbfile" >> "$_hreq"
	else
		printf '\r\n' >> "$_hreq"
	fi
}

# _http_res_parse <raw_response> → sets _HTTP_STATUS, writes body to stdout
_http_res_parse() {
	_hraw="$1"

	# Split headers and body on first \r\n\r\n
	_hbody="$(printf '%s' "$_hraw" | sed '1,/^\r$/d')"
	_hhdr="$(printf '%s' "$_hraw" | sed '/^\r$/q')"

	# Extract status code from first line
	_hsline="$(printf '%s' "$_hhdr" | head -1)"
	_HTTP_STATUS="${_hsline#* }"
	_HTTP_STATUS="${_HTTP_STATUS%% *}"

	# Handle chunked transfer encoding
	if printf '%s' "$_hhdr" | grep -qi "Transfer-Encoding:.*chunked"; then
		_hbody="$(printf '%s\n' "$_hbody" | awk '
		/^[0-9a-fA-F]+\r?$/ {
			clen = strtonum("0x"$1)
			if (clen == 0) exit
			chunk = ""
			for (i = 1; i <= clen; i++) {
				r = getline; chunk = chunk $0 "\n"
			}
			printf "%s", chunk
		}')"
		_hbody="${_hbody%$(printf '\n')}"
	fi

	printf '%s' "$_hbody"
}

# _http_raw <method> <url> <body_file> [headers...]
# Core transport. Sets _HTTP_STATUS, writes body to stdout.
# If _HTTP_OUTFILE is set, writes raw body to that file instead.
_http_raw() {
	_hmethod="$1" _hrurl="$2" _hbfile="$3"; shift 3
	_hretry=0

	# Mock short-circuit
	if [ "${MOCK_HTTP:-0}" = "1" ]; then
		if [ "${MOCK_FAIL:-0}" = "1" ]; then
			_ERROR="http_get: mock failure"
			return "${MOCK_STATUS:-1}"
		fi
		_HTTP_STATUS="${MOCK_HTTP_STATUS:-200}"
		printf '%s' "${MOCK_RESPONSE:-}"
		return 0
	fi

	_url_parse "$_hrurl"
	_http_build_req "$_hmethod" "$_hpath" "$_hhost" "$_hbfile" "$@"

	while [ $_hretry -le "$_HTTP_RETRY" ]; do
		_hretry=$((_hretry + 1))

		if [ -n "${_HTTP_OUTFILE:-}" ]; then
			# ---- File output mode (binary-safe) ----
			case "$_hproto" in
			https|wss)
				_hwrap="/tmp/ayu-ssl-wrap.$$"
				cat > "$_hwrap" << ENDWRAP
#!/bin/sh
exec 3<&0 3>&1
cat "$_hreq" | ssl_client -s 3 -n "\$SNI_HOST" | sed '1,/^\r\$/d' > "\$OUTFILE"
ENDWRAP
				chmod +x "$_hwrap"
				_herr="/tmp/ayu-ssl-err.$$"
				OUTFILE="$_HTTP_OUTFILE" SNI_HOST="$_hhost" \
					nc "$_hhost" "$_hport" -e "$_hwrap" -w "$_HTTP_TIMEOUT" >/dev/null 2>"$_herr"
				_hrc=$?
				if [ $_hrc -ne 0 ] || [ ! -s "$_HTTP_OUTFILE" ]; then
					_errmsg="$(tr '\n' ' ' <"$_herr" 2>/dev/null)"
					log_err "_http_raw https-file fail: hrc=$_hrc outSz=$(wc -c <"$_HTTP_OUTFILE" 2>/dev/null) ncerr=[$_errmsg] url=$_hrurl"
				fi
				rm -f "$_hwrap" "$_herr"
				;;
			*)
				cat "$_hreq" | nc "$_hhost" "$_hport" -w "$_HTTP_TIMEOUT" \
					| sed '1,/^\r$/d' > "$_HTTP_OUTFILE"
				_hrc=$?
				;;
			esac
			if [ $_hrc -eq 0 ] && [ -s "$_HTTP_OUTFILE" ]; then
				rm -f "$_hreq"; return 0
			fi
		else
			# ---- String output mode ----
			case "$_hproto" in
			https|wss)
				_hwrap="/tmp/ayu-ssl-wrap.$$"
				cat > "$_hwrap" << ENDWRAP
#!/bin/sh
exec 3<&0 3>&1
exec 1>&2
cat "$_hreq" | ssl_client -s 3 -n "\$SNI_HOST"
ENDWRAP
				chmod +x "$_hwrap"
				_hres="$(SNI_HOST="$_hhost" nc "$_hhost" "$_hport" -e "$_hwrap" -w "$_HTTP_TIMEOUT" 2>&1)"
				_hrc=$?
				rm -f "$_hwrap"
				;;
			*)
				_hres="$(cat "$_hreq" | nc "$_hhost" "$_hport" -w "$_HTTP_TIMEOUT" 2>&1)"
				_hrc=$?
				;;
			esac

			if [ $_hrc -eq 0 ] && [ -n "$_hres" ]; then
				rm -f "$_hreq"
				_http_res_parse "$_hres" || return 1
				return 0
			fi
		fi
		log_warn "_http_raw retry $_hretry/$_HTTP_RETRY: $_hrurl"
	done

	rm -f "$_hreq"
	_ERROR="http failed after $_HTTP_RETRY retries: $_hrurl"
	return 1
}

# http_get <url> [header...]
http_get() {
	_hurl="$1"; shift
	_http_raw GET "$_hurl" "" "$@"
}

# http_get_file <url> <output_file> [header...]
http_get_file() {
	_hurl="$1" _hout="$2"; shift 2
	_HTTP_OUTFILE="$_hout" _http_raw GET "$_hurl" "" "$@"
	_hrc=$?; unset _HTTP_OUTFILE; return $_hrc
}

# http_post <url> <body> [header...]
http_post() {
	_hurl="$1" _hdata="$2"; shift 2
	_htmp="/tmp/ayu-body.$$"
	printf '%s' "$_hdata" > "$_htmp"
	_http_raw POST "$_hurl" "$_htmp" "$@"
	_hrc=$?; rm -f "$_htmp"; return $_hrc
}

# http_post_file <url> <file> [header...]
http_post_file() {
	_hurl="$1" _hfile="$2"; shift 2
	_http_raw POST "$_hurl" "$_hfile" "$@"
}
