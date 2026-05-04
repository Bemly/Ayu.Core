# plugin/sync.sh — cross-platform message sync
# Forwards messages between QQ, Telegram, Discord based on etc/sync.conf
# Called by dispatch: sync_handler <pf> <evt> <uid> <txt> <raw>

[ -z "${_HB:-}" ] && _HB="$(pwd)"

# Source message APIs (harmless if already sourced)
. "$_HB/adapter/qq/message.sh"
. "$_HB/adapter/qq/file.sh"
. "$_HB/adapter/qq/group.sh"
. "$_HB/adapter/qq/group.sh"
. "$_HB/adapter/telegram/message.sh"
. "$_HB/adapter/telegram/file.sh"
. "$_HB/adapter/discord/message.sh"

# Extract sender display name from platform-specific raw JSON
# _reaction_code <json_escaped_emoji> -> decimal Unicode codepoint
# NOTE: surrogate pair logic mirrors utf8_decode in lib/url.sh — same hex parsing, different output
_reaction_code() {
	# Try JSON-escaped \uXXXX[\uYYYY] format first
	_code="$(printf '%s' "$1" | awk '
	match($0, /\\u[Dd][89ABab][0-9A-Fa-f][0-9A-Fa-f]\\u[Dd][C-Fc-f][0-9A-Fa-f][0-9A-Fa-f]/) {
		h1 = substr($0, 3, 4); lo = substr($0, 9, 4)
		cp = 0x10000 + (("0x"h1) - 0xD800) * 0x400 + (("0x"lo) - 0xDC00)
		printf "%d", cp; exit
	}
	match($0, /\\u[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/) {
		h = substr($0, 3, 4); printf "%d", "0x"h; exit
	}
	')"
	if [ -n "$_code" ]; then
		printf '%s' "$_code"
	else
		# Raw emoji character: decode UTF-8 bytes via od
		printf '%s' "$1" | od -An -tu1 | awk '{
		b1 = $1; b2 = $2; b3 = $3; b4 = $4
		if (b1 < 0x80) cp = b1
		else if (b1 < 0xE0) cp = (b1 - 0xC0) * 64 + (b2 - 0x80)
		else if (b1 < 0xF0) cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
		else cp = (b1 - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80)
		printf "%d", cp
		}'
	fi
}


_sync_get_sender() {
	_pf="$1" _raw="$2"
	case "$_pf" in
	qq)
		_gm="$(json_get "$_raw" group_member)"
		if [ -n "$_gm" ] && [ "$_gm" != "NOTFOUND" ]; then
			_nm="$(json_get "$_gm" nickname)"
			[ -n "$_nm" ] && [ "$_nm" != "NOTFOUND" ] && { printf '%s' "$_nm"; return; }
			_nm="$(json_get "$_gm" card)"
			[ -n "$_nm" ] && [ "$_nm" != "NOTFOUND" ] && { printf '%s' "$_nm"; return; }
		fi
		_fr="$(json_get "$_raw" friend)"
		if [ -n "$_fr" ] && [ "$_fr" != "NOTFOUND" ]; then
			_nm="$(json_get "$_fr" nickname)"
			[ -n "$_nm" ] && [ "$_nm" != "NOTFOUND" ] && { printf '%s' "$_nm"; return; }
		fi
		json_get "$_raw" sender_id
		;;
	telegram)
		_from="$(json_get "$_raw" from)"
		if [ -n "$_from" ] && [ "$_from" != "NOTFOUND" ]; then
			_fn="$(json_get "$_from" first_name)"
			_ln="$(json_get "$_from" last_name)"
			if [ -n "$_fn" ] && [ "$_fn" != "NOTFOUND" ]; then
				if [ -n "$_ln" ] && [ "$_ln" != "NOTFOUND" ]; then
					printf '%s %s' "$_fn" "$_ln"
				else
					printf '%s' "$_fn"
				fi
				return
			fi
			_un="$(json_get "$_from" username)"
			[ -n "$_un" ] && [ "$_un" != "NOTFOUND" ] && { printf '@%s' "$_un"; return; }
		fi
		printf 'unknown'
		;;
	*) printf 'unknown' ;;
	esac
}

# Extract source chat/channel/group ID as config lookup key
_sync_source_id() {
	_pf="$1" _raw="$2"
	case "$_pf" in
	qq)
		# message_receive: group_id is nested in group.group_id
		_group="$(json_get "$_raw" group 2>/dev/null)" || _group=""
		if [ -n "$_group" ] && [ "$_group" != "NOTFOUND" ]; then
			_gid="$(json_get "$_group" group_id 2>/dev/null)" || _gid=""
			if [ -n "$_gid" ] && [ "$_gid" != "NOTFOUND" ]; then
				printf 'group/%s' "$_gid"; return
			fi
		fi
		# non-message events: group_id at top level
		_gid="$(json_get "$_raw" group_id 2>/dev/null)" || _gid=""
		if [ -n "$_gid" ] && [ "$_gid" != "NOTFOUND" ]; then
			printf 'group/%s' "$_gid"; return
		fi
		# private messages
		_pid="$(json_get "$_raw" peer_id 2>/dev/null)" || _pid=""
		[ -n "$_pid" ] && [ "$_pid" != "NOTFOUND" ] && printf 'private/%s' "$_pid"
		;;
	telegram)
		_chat="$(json_get "$_raw" chat 2>/dev/null)" || _chat=""
		if [ -n "$_chat" ] && [ "$_chat" != "NOTFOUND" ]; then
			_cid="$(json_get "$_chat" id 2>/dev/null)" || _cid=""
			printf '%s' "$_cid"
		fi
		;;
	esac
}

# Upload file to Telegram via multipart/form-data
_sync_tg_multipart() {
	_chat="$1" _thr="$2" _file="$3" _fname="$4" _cap="$5"
	_bound="ayu-$$-$(date +%s)"
	_tmp="/tmp/tg-up-$$"
	# Build multipart body
	> "$_tmp"
	printf '--%s\r\n' "$_bound" >> "$_tmp"
	printf 'Content-Disposition: form-data; name="chat_id"\r\n\r\n' >> "$_tmp"
	printf '%s\r\n' "$_chat" >> "$_tmp"
	printf '--%s\r\n' "$_bound" >> "$_tmp"
	printf 'Content-Disposition: form-data; name="photo"; filename="%s"\r\n' "$_fname" >> "$_tmp"
	printf 'Content-Type: application/octet-stream\r\n\r\n' >> "$_tmp"
	cat "$_file" >> "$_tmp"
	printf '\r\n' >> "$_tmp"
	if [ -n "$_cap" ]; then
		printf '--%s\r\n' "$_bound" >> "$_tmp"
		printf 'Content-Disposition: form-data; name="caption"\r\n\r\n' >> "$_tmp"
		printf '%s\r\n' "$_cap" >> "$_tmp"
	fi
	if [ -n "$_thr" ]; then
		printf '--%s\r\n' "$_bound" >> "$_tmp"
		printf 'Content-Disposition: form-data; name="message_thread_id"\r\n\r\n' >> "$_tmp"
		printf '%s\r\n' "$_thr" >> "$_tmp"
	fi
	printf '--%s--\r\n' "$_bound" >> "$_tmp"
	# Send
	_url="${TG_API_BASE}/sendPhoto"
	if http_post_file "$_url" "$_tmp" \
		"Content-Type: multipart/form-data; boundary=$_bound" \
		"X-Ayu-Token: ${TG_API_SECRET}" >/dev/null; then
		rm -f "$_tmp"; return 0
	else
		rm -f "$_tmp"; return 1
	fi
}

# Forward QQ images to TG (GIF→sendAnimation, static→sendPhoto)
