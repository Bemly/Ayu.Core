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
	printf '%s' "$1" | awk 'BEGIN {
		split("0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15", hv)
		split("0123456789ABCDEF", hd, "")
	}
	{
		s = $0
		while (match(s, /\\u[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
			h = substr(s, RSTART+2, 4)
			cp = 0
			for (i = 1; i <= 4; i++) {
				cc = substr(h, i, 1)
				if (cc == "a") cc = "A"; else if (cc == "b") cc = "B"
				else if (cc == "c") cc = "C"; else if (cc == "d") cc = "D"
				else if (cc == "e") cc = "E"; else if (cc == "f") cc = "F"
				for (j = 1; j <= 16; j++) {
					if (cc == hd[j]) { cp = cp * 16 + hv[j]; break }
				}
			}
			adv = 6
			# UTF-16 surrogate pair? (D800-DBFF followed by DC00-DFFF)
			if (cp >= 0xD800 && cp <= 0xDBFF) {
				_rs = RSTART; nx = substr(s, RSTART+6, 12)
				if (match(nx, /^\\u[Dd][C-Fc-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
					RSTART = _rs; lo = 0; lh = substr(nx, 3, 4)
					for (i = 1; i <= 4; i++) {
						lc = substr(lh, i, 1)
						if (lc == "a") lc = "A"; else if (lc == "b") lc = "B"
						else if (lc == "c") lc = "C"; else if (lc == "d") lc = "D"
						else if (lc == "e") lc = "E"; else if (lc == "f") lc = "F"
						for (j = 1; j <= 16; j++) {
							if (lc == hd[j]) { lo = lo * 16 + hv[j]; break }
						}
					}
					cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
					adv = 12
				}
			}
			if (cp < 0x80) {
				u = sprintf("%c", cp)
			} else if (cp < 0x800) {
				u = sprintf("%c%c", 0xC0 + int(cp/64), 0x80 + cp%64)
			} else if (cp < 0x10000) {
				u = sprintf("%c%c%c", 0xE0 + int(cp/4096), 0x80 + int((cp%4096)/64), 0x80 + cp%64)
			} else {
				u = sprintf("%c%c%c%c", 0xF0 + int(cp/262144), 0x80 + int((cp%262144)/4096), 0x80 + int((cp%4096)/64), 0x80 + cp%64)
			}
			s = substr(s, 1, RSTART-1) u substr(s, RSTART+adv)
		}
		print s
	}'
}
