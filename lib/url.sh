# hush-url/lib/url.sh — pure shell URL encode/decode + UTF-8 decode
# Works in busybox:musl, no external dependencies
#
# url_encode <string>  → percent-encoded string
# url_decode <string>  → decoded string
# utf8_decode <string> → \uXXXX → UTF-8 bytes

# Percent-encode non-unreserved ASCII characters (RFC 3986)
# Unreserved: A-Z a-z 0-9 - _ . ~  (NOT encoded)
# Encode % first so already-encoded strings double-encode correctly
url_encode() {
	printf '%s' "$1" | sed '
		s/%/%25/g
		s/ /%20/g
		s/!/%21/g
		s/"/%22/g
		s/#/%23/g
		s/\$/%24/g
		s/&/%26/g
		s/'\''/%27/g
		s/(/%28/g
		s/)/%29/g
		s/\*/%2A/g
		s/+/%2B/g
		s/,/%2C/g
		s/\//%2F/g
		s/:/%3A/g
		s/;/%3B/g
		s/</%3C/g
		s/=/%3D/g
		s/>/%3E/g
		s/?/%3F/g
		s/@/%40/g
		s/\[/%5B/g
		s/\\/%5C/g
		s/\]/%5D/g
		s/\^/%5E/g
		s/`/%60/g
		s/{/%7B/g
		s/|/%7C/g
		s/}/%7D/g
	'
}

# Decode percent-encoded strings (+ → space, %XX → char)
# Decode %25 first so double-encoded strings (%2520) resolve correctly
url_decode() {
	printf '%s' "$1" | sed '
		s/+/ /g
		s/%25/%/g
		s/%20/ /g
		s/%21/!/g
		s/%22/"/g
		s/%23/#/g
		s/%24/$/g
		s/%26/\&/g
		s/%27/'\''/g
		s/%28/(/g
		s/%29/)/g
		s/%2A/*/g
		s/%2B/+/g
		s/%2C/,/g
		s/%2E/./g
		s/%2F/\//g
		s/%3A/:/g
		s/%3B/;/g
		s/%3C/</g
		s/%3D/=/g
		s/%3E/>/g
		s/%3F/?/g
		s/%40/@/g
		s/%5B/[/g
		s/%5C/\\/g
		s/%5D/]/g
		s/%5E/^/g
		s/%5F/_/g
		s/%60/`/g
		s/%7B/{/g
		s/%7C/|/g
		s/%7D/}/g
		s/%7E/~/g
	'
}

# Convert \uXXXX JSON unicode escapes to UTF-8 bytes
# Handles UTF-16 surrogate pairs (\uD800-\uDBFF followed by \uDC00-\uDFFF)
# U+0000..U+007F → 1 byte, U+0080..U+07FF → 2 bytes,
# U+0800..U+FFFF → 3 bytes, U+10000..U+10FFFF → 4 bytes
utf8_decode() {
	printf '%s' "$1" | awk '
	# Portable hex → number (busybox/mawk awk do not convert "0x.." strings)
	function hx(h,   i, cc, p, v) {
		v = 0
		for (i = 1; i <= 4; i++) {
			cc = toupper(substr(h, i, 1))
			p = index("0123456789ABCDEF", cc)
			if (p == 0) return -1
			v = v * 16 + p - 1
		}
		return v
	}
	{
		s = $0
		while (match(s, /\\u[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
			cp = hx(substr(s, RSTART+2, 4))
			if (cp < 0) { cp = 0 }
			adv = 6
			# UTF-16 surrogate pair? (D800-DBFF followed by DC00-DFFF)
			if (cp >= 55296 && cp <= 56319) {
				nx = substr(s, RSTART+6, 12)
				if (nx ~ /^\\u[Dd][C-Fc-f][0-9A-Fa-f][0-9A-Fa-f]/) {
					lo = hx(substr(nx, 3, 4))
					if (lo >= 56320 && lo <= 57343) {
						cp = 65536 + (cp - 55296) * 1024 + (lo - 56320)
						adv = 12
					}
				}
			}
			if (cp < 128) {
				u = sprintf("%c", cp)
			} else if (cp < 2048) {
				u = sprintf("%c%c", 192 + int(cp/64), 128 + cp%64)
			} else if (cp < 65536) {
				u = sprintf("%c%c%c", 224 + int(cp/4096), 128 + int((cp%4096)/64), 128 + cp%64)
			} else {
				u = sprintf("%c%c%c%c", 240 + int(cp/262144), 128 + int((cp%262144)/4096), 128 + int((cp%4096)/64), 128 + cp%64)
			}
			s = substr(s, 1, RSTART-1) u substr(s, RSTART+adv)
		}
		print s
	}'
}
