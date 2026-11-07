# plugin/sync.sh — cross-platform message sync
# Forwards messages between QQ, Telegram, Discord based on etc/sync.conf
# Called by dispatch: sync_handler <pf> <evt> <uid> <txt> <raw>

[ -z "${_HB:-}" ] && _HB="$(pwd)"

# Source message APIs (harmless if already sourced)
. "$_HB/adapter/qq/message.sh"
. "$_HB/adapter/qq/file.sh"
. "$_HB/adapter/qq/group.sh"
. "$_HB/adapter/telegram/message.sh"
. "$_HB/adapter/telegram/file.sh"
. "$_HB/adapter/discord/message.sh"

	_SYNC_MAX_FILE_SIZE="${_SYNC_MAX_FILE_SIZE:-20000000}"

# _emoji_url_encode <json_escaped_or_raw_emoji> -> URL-encoded UTF-8 (%XX%XX...)
# Used for Discord reaction API (emoji in URL path must be URL-encoded)
_emoji_url_encode() {
	_enc="$(printf '%s' "$1" | awk '
	match($0, /\\u[Dd][89ABab][0-9A-Fa-f][0-9A-Fa-f]\\u[Dd][C-Fc-f][0-9A-Fa-f][0-9A-Fa-f]/) {
		h1 = substr($0, 3, 4); lo = substr($0, 9, 4)
		cp = 0x10000 + (("0x"h1) - 0xD800) * 0x400 + (("0x"lo) - 0xDC00)
		_utf8hex(cp); exit
	}
	match($0, /\\u[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/) {
		h = substr($0, 3, 4)
		_utf8hex("0x"h); exit
	}
	function _utf8hex(cp) {
		if (cp < 0x80) { printf "%%%02X", cp; return }
		if (cp < 0x800) { printf "%%%02X%%%02X", 0xC0+(cp/64), 0x80+(cp%64); return }
		if (cp < 0x10000) { printf "%%%02X%%%02X%%%02X", 0xE0+(cp/4096), 0x80+((cp/64)%64), 0x80+(cp%64); return }
		printf "%%%02X%%%02X%%%02X%%%02X", 0xF0+(cp/262144), 0x80+((cp/4096)%64), 0x80+((cp/64)%64), 0x80+(cp%64)
	}
	')"
	if [ -n "$_enc" ]; then
		printf '%s' "$_enc"
	else
		printf '%s' "$1" | od -An -tx1 | awk '{for(i=1;i<=NF;i++) printf "%%%s", toupper($i)}'
	fi
}

# Extract sender display name from platform-specific raw JSON
# _reaction_code <json_escaped_emoji> -> decimal Unicode codepoint
# NOTE: surrogate pair logic mirrors utf8_decode in lib/url.sh — same hex parsing, different output
_reaction_code() {
	# Try JSON-escaped \uXXXX[\uYYYY] format first
	_code="$(printf '%s' "$1" | awk '
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
	match($0, /\\u[Dd][89ABab][0-9A-Fa-f][0-9A-Fa-f]\\u[Dd][C-Fc-f][0-9A-Fa-f][0-9A-Fa-f]/) {
		h1 = hx(substr($0, 3, 4)); lo = hx(substr($0, 9, 4))
		if (h1 >= 0 && lo >= 0) {
			printf "%d", 65536 + (h1 - 55296) * 1024 + (lo - 56320)
			exit
		}
	}
	match($0, /\\u[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/) {
		h = hx(substr($0, 3, 4))
		if (h >= 0) { printf "%d", h; exit }
	}
	')"
	if [ -n "$_code" ]; then
		printf '%s' "$_code"
	else
		# Raw emoji character: decode UTF-8 bytes via od
		printf '%s' "$1" | od -An -tu1 | awk '{
		b1 = $1; b2 = $2; b3 = $3; b4 = $4
		if (b1 < 128) cp = b1
		else if (b1 < 224) cp = (b1 - 192) * 64 + (b2 - 128)
		else if (b1 < 240) cp = (b1 - 224) * 4096 + (b2 - 128) * 64 + (b3 - 128)
		else cp = (b1 - 240) * 262144 + (b2 - 128) * 4096 + (b3 - 128) * 64 + (b4 - 128)
		printf "%d", cp
		}'
	fi
}


# _sync_short_id <id> [len] — first N chars of a platform id.
# Snowflakes / openids are 19-32 chars and make every relayed line unreadable;
# the prefix is enough to tell senders apart inside one group.
_sync_short_id() {
	_ssi_len="${2:-7}"
	[ -n "$1" ] || return 0
	printf '%s' "$1" | cut -c1-"$_ssi_len"
}

# _sync_qqbot_nick <group_openid> <openid> — a display name bound by a group
# admin (`@bot @someone 昵称`, see adapter/qqbot/admin.sh). Bindings live in
# var/state/qqbot-nick, so the relay can use them without loading the adapter.
_sync_qqbot_nick() {
	[ -n "$1" ] && [ -n "$2" ] || return 0
	_sqn_f="${_STATE_DIR:-$_HB/var/state}/qqbot-nick/$1"
	[ -f "$_sqn_f" ] || return 0
	awk -F '\t' -v id="$2" '$1 == id { print $2; exit }' "$_sqn_f"
}

_sync_get_sender() {
	_pf="$1" _raw="$2"
	case "$_pf" in
	qq)
		_nm=""
		_gm="$(json_get "$_raw" group_member)"
		if [ -n "$_gm" ] && [ "$_gm" != "NOTFOUND" ]; then
			_nm="$(json_get "$_gm" nickname)"
			[ "$_nm" = "NOTFOUND" ] && _nm=""
			[ -z "$_nm" ] && _nm="$(json_get "$_gm" card)"
			[ "$_nm" = "NOTFOUND" ] && _nm=""
		fi
		if [ -z "$_nm" ]; then
			_fr="$(json_get "$_raw" friend)"
			if [ -n "$_fr" ] && [ "$_fr" != "NOTFOUND" ]; then
				_nm="$(json_get "$_fr" nickname)"
				[ "$_nm" = "NOTFOUND" ] && _nm=""
			fi
		fi
		_sid="$(json_get "$_raw" sender_id 2>/dev/null)"
		[ "$_sid" = "NOTFOUND" ] && _sid=""
		[ -z "$_nm" ] && _nm="$_sid"
		printf "%s(%s)" "$_nm" "$_sid"
		;;
	telegram)
		_nm="" _id=""
		_from="$(json_get "$_raw" from)"
		if [ -n "$_from" ] && [ "$_from" != "NOTFOUND" ]; then
			_fn="$(json_get "$_from" first_name)"
			_ln="$(json_get "$_from" last_name)"
			_un="$(json_get "$_from" username)"
			_id="$(json_get "$_from" id 2>/dev/null)"
			if [ -n "$_fn" ] && [ "$_fn" != "NOTFOUND" ]; then
				if [ -n "$_ln" ] && [ "$_ln" != "NOTFOUND" ]; then
					_nm="$_fn $_ln"
				else
					_nm="$_fn"
				fi
			elif [ -n "$_un" ] && [ "$_un" != "NOTFOUND" ]; then
				_nm="@$_un"
			fi
		fi
		[ -z "$_nm" ] && _nm="unknown"
		if [ -n "$_un" ] && [ "$_un" != "NOTFOUND" ]; then
			_id="@$_un"
		else
			_id="$(_sync_short_id "$_id")"
		fi
		printf "%s(%s)" "$_nm" "$_id"
		;;
	qqbot)
		# Official webhook events carry no nickname — only an openid. Show the
		# first 7 chars as the display name; the full openid stays in the maps.
		_a="$(json_get "$_raw" author 2>/dev/null)" || _a=""
		_id="$(json_get "$_a" member_openid 2>/dev/null)" || _id=""
		case "$_id" in ''|NOTFOUND|null) _id="$(json_get "$_a" user_openid 2>/dev/null)" ;; esac
		case "$_id" in ''|NOTFOUND|null) _id="$(json_get "$_a" id 2>/dev/null)" ;; esac
		case "$_id" in ''|NOTFOUND|null) _id="" ;; esac
		_short="$(_sync_short_id "$_id")"
		[ -n "$_short" ] || _short="unknown"
		_nick="$(_sync_qqbot_nick "$(json_get "$_raw" group_openid 2>/dev/null)" "$_id")"
		if [ -n "$_nick" ]; then
			printf "%s(qq#%s)" "$_nick" "$_short"
		else
			printf "qq#%s" "$_short"
		fi
		;;
	discord)
		_nm="" _id=""
		_author="$(json_get "$_raw" author 2>/dev/null)" || _author=""
		if [ -n "$_author" ] && [ "$_author" != "NOTFOUND" ]; then
			_un="$(json_get "$_author" username 2>/dev/null)" || _un=""
			_dn="$(json_get "$_author" global_name 2>/dev/null)" || _dn=""
			_id="$(json_get "$_author" id 2>/dev/null)" || _id=""
			if [ -n "$_dn" ] && [ "$_dn" != "NOTFOUND" ]; then
				_nm="$_dn"
			elif [ -n "$_un" ] && [ "$_un" != "NOTFOUND" ]; then
				_nm="$_un"
			fi
		fi
		[ -z "$_nm" ] && _nm="unknown"
		[ "$_id" = "NOTFOUND" ] && _id=""
		printf "%s(%s)" "$_nm" "$(_sync_short_id "$_id")"
		;;
	*) printf "unknown" ;;
	esac
}

# _sync_src_msgid <platform> <raw> — the source platform's own message id
# (QQ uses message_seq, TG message_id, DC/QQ-bot id). Reverse maps are keyed on
# it so a recall on the source platform can delete the forwarded copies.
_sync_src_msgid() {
	case "$1" in
		qq)       json_get "$2" message_seq 2>/dev/null ;;
		telegram) json_get "$2" message_id 2>/dev/null ;;
		discord)  json_get "$2" id 2>/dev/null ;;
		qqbot)    json_get "$2" id 2>/dev/null ;;
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
	qqbot)
		_gid="$(json_get "$_raw" group_openid 2>/dev/null)" || _gid=""
		case "$_gid" in ''|NOTFOUND|null) _gid="" ;; esac
		if [ -n "$_gid" ]; then printf 'group/%s' "$_gid"; return; fi
		_ch="$(json_get "$_raw" channel_id 2>/dev/null)" || _ch=""
		case "$_ch" in ''|NOTFOUND|null) _ch="" ;; esac
		if [ -n "$_ch" ]; then printf 'channel/%s' "$_ch"; return; fi
		_au="$(json_get "$_raw" author 2>/dev/null)" || _au=""
		_oid="$(json_get "$_au" user_openid 2>/dev/null)" || _oid=""
		case "$_oid" in ''|NOTFOUND|null) _oid="$(json_get "$_au" id 2>/dev/null)" ;; esac
		case "$_oid" in ''|NOTFOUND|null) _oid="" ;; esac
		[ -n "$_oid" ] && printf 'private/%s' "$_oid"
		;;
	telegram)
		_chat="$(json_get "$_raw" chat 2>/dev/null)" || _chat=""
		if [ -n "$_chat" ] && [ "$_chat" != "NOTFOUND" ]; then
			_cid="$(json_get "$_chat" id 2>/dev/null)" || _cid=""
			printf '%s' "$_cid"
			_thr="$(json_get "$_raw" message_thread_id 2>/dev/null)" || _thr=""
			[ -n "$_thr" ] && [ "$_thr" != "NOTFOUND" ] && printf '/%s' "$_thr"
		fi
		;;
	discord)
		_cid="$(json_get "$_raw" channel_id 2>/dev/null)" || _cid=""
		if [ -n "$_cid" ] && [ "$_cid" != "NOTFOUND" ]; then
			printf '%s' "$_cid"
		fi
		;;
	esac
}

# Upload file to Telegram via multipart/form-data
# Usage: _sync_tg_multipart <chat> <thread> <file> <filename> <method> <field> [mime] [caption] [duration]
_sync_tg_multipart() {
	# NOTE: hush has no `local`. Every scratch name is prefixed (_tgm_) so the
	# body cannot clobber the caller's variables — leaking the multipart file of
	# the *caller* (which it deletes after upload) was the historical bug.
	_tgm_chat="$1" _tgm_thr="$2" _tgm_file="$3" _tgm_fname="$4"
	_tgm_method="$5" _tgm_field="$6"
	_tgm_mime="${7:-application/octet-stream}" _tgm_cap="${8:-}" _tgm_dur="${9:-}"
	_tgm_bound="ayu-$$-$(date +%s)"
	_tgm_tmp="/tmp/tg-up-$$"
	> "$_tgm_tmp"
	printf '--%s\r\n' "$_tgm_bound" >> "$_tgm_tmp"
	printf 'Content-Disposition: form-data; name="chat_id"\r\n\r\n' >> "$_tgm_tmp"
	printf '%s\r\n' "$_tgm_chat" >> "$_tgm_tmp"
	if [ -n "$_tgm_thr" ]; then
		printf '--%s\r\n' "$_tgm_bound" >> "$_tgm_tmp"
		printf 'Content-Disposition: form-data; name="message_thread_id"\r\n\r\n' >> "$_tgm_tmp"
		printf '%s\r\n' "$_tgm_thr" >> "$_tgm_tmp"
	fi
	printf '--%s\r\n' "$_tgm_bound" >> "$_tgm_tmp"
	printf 'Content-Disposition: form-data; name="%s"; filename="%s"\r\n' "$_tgm_field" "$_tgm_fname" >> "$_tgm_tmp"
	printf 'Content-Type: %s\r\n\r\n' "$_tgm_mime" >> "$_tgm_tmp"
	cat "$_tgm_file" >> "$_tgm_tmp"
	printf '\r\n' >> "$_tgm_tmp"
	if [ -n "$_tgm_cap" ]; then
		printf '--%s\r\n' "$_tgm_bound" >> "$_tgm_tmp"
		printf 'Content-Disposition: form-data; name="caption"\r\n\r\n' >> "$_tgm_tmp"
		printf '%s\r\n' "$_tgm_cap" >> "$_tgm_tmp"
	fi
	if [ -n "$_tgm_dur" ]; then
		printf '--%s\r\n' "$_tgm_bound" >> "$_tgm_tmp"
		printf 'Content-Disposition: form-data; name="duration"\r\n\r\n' >> "$_tgm_tmp"
		printf '%s\r\n' "$_tgm_dur" >> "$_tgm_tmp"
	fi
	printf '--%s--\r\n' "$_tgm_bound" >> "$_tgm_tmp"
	_tgm_url="${TG_API_BASE}/${_tgm_method}"
	if http_post_file "$_tgm_url" "$_tgm_tmp" \
		"Content-Type: multipart/form-data; boundary=$_tgm_bound" \
		"$_TG_AUTH" >/dev/null; then
		rm -f "$_tgm_tmp"; return 0
	else
		rm -f "$_tgm_tmp"; return 1
	fi
}

# Upload file to Discord via multipart/form-data (bot auth)
# Usage: _sync_dc_multipart <channel_id> <file_path> <filename> <mime> [caption]
_sync_dc_multipart() {
	# Same no-`local` rule as above: all scratch names use the _dcm_ prefix.
	_dcm_cid="$1" _dcm_file="$2" _dcm_fname="$3" _dcm_mime="$4" _dcm_cap="${5:-}"
	_dcm_bound="ayu-dc-$$-$(date +%s)"
	_dcm_tmp="/tmp/dc-up-$$"
	> "$_dcm_tmp"
	# JSON payload part
	_dcm_json="$(json_obj "content" "$_dcm_cap")"
	printf '--%s\r\n' "$_dcm_bound" >> "$_dcm_tmp"
	printf 'Content-Disposition: form-data; name="payload_json"\r\n' >> "$_dcm_tmp"
	printf 'Content-Type: application/json\r\n\r\n' >> "$_dcm_tmp"
	printf '%s\r\n' "$_dcm_json" >> "$_dcm_tmp"
	# File part
	printf '--%s\r\n' "$_dcm_bound" >> "$_dcm_tmp"
	printf 'Content-Disposition: form-data; name="files[0]"; filename="%s"\r\n' "$_dcm_fname" >> "$_dcm_tmp"
	printf 'Content-Type: %s\r\n\r\n' "$_dcm_mime" >> "$_dcm_tmp"
	cat "$_dcm_file" >> "$_dcm_tmp"
	printf '\r\n--%s--\r\n' "$_dcm_bound" >> "$_dcm_tmp"
	# Send
	_dcm_url="${DC_API_BASE}/channels/${_dcm_cid}/messages"
	if http_post_file "$_dcm_url" "$_dcm_tmp" \
		"Content-Type: multipart/form-data; boundary=$_dcm_bound" \
		"Authorization: Bot ${DC_TOKEN}" \
			"${_DC_AYU_AUTH:-}" >/dev/null; then
		rm -f "$_dcm_tmp"; return 0
	else
		rm -f "$_dcm_tmp"; return 1
	fi
}

# ---- shared download/extract helpers ----

# _tg_download_file <file_id> <prefix> <tag>
# Downloads TG file: getFile → file_path → http_get_file → temp file.
# Sets globals: _tg_df_path (temp file), _tg_df_furi (file:// URI), _tg_df_name.
# Errors prepended to _ERROR. Returns 0 on success.
_tg_download_file() {
	_fid="$1" _prefix="$2" _tag="$3"
	tg_getFile "$_fid" > "/tmp/tg-fp-$$" 2>/dev/null || {
		_ERROR="tg.getFile(${_tag}): $_ERROR"; return 1
	}
	_fp="$(cat "/tmp/tg-fp-$$")"; rm -f "/tmp/tg-fp-$$"
	_path="$(json_get "$_fp" file_path 2>/dev/null)" || _path=""
	if [ -z "$_path" ] || [ "$_path" = "NOTFOUND" ]; then
		_ERROR="tg.download(${_tag}): no file_path fid=$_fid"; return 1
	fi
	_fname="${_path##*/}"
	_ts=$(date +%s)
	_ext=".${_fname##*.}"; [ "$_ext" = ".$_fname" ] && _ext=""
	_tg_df_path="/tmp/img/sync-${_prefix}-tg-$$-$_ts$_ext"
	_tg_df_furi="file:///root/img/sync-${_prefix}-tg-$$-$_ts$_ext"
	_tg_df_name="$_fname"
	_url="https://${TG_API_HOST}/file/bot${TG_TOKEN}/${_path}"
	http_get_file "$_url" "$_tg_df_path" "$_TG_AUTH" || {
		_ERROR="tg.download(${_tag}): $_ERROR"; rm -f "$_tg_df_path"; return 1
	}
	log_debug "sync: tg download OK tag=$_tag sz=$(wc -c < "$_tg_df_path" 2>/dev/null)"
	return 0
}

# _qq_extract_segments <raw_json> <type>
# Extracts QQ segments of given type (image/file/record/video). One per line.
# Returns 1 if none found.
_qq_extract_segments() {
	_raw="$1" _type="$2"
	_segs="$(json_get "$_raw" segments 2>/dev/null)" || _segs=""
	if [ -z "$_segs" ] || [ "$_segs" = "NOTFOUND" ]; then return 1; fi
	_result="$(printf '%s' "$_segs" | sed 's/},{"type"/\
{"type"/g' | grep "\"type\":\"$_type\"")"
	[ -z "$_result" ] && return 1
	printf '%s\n' "$_result"
	return 0
}

# Forward QQ images to TG (GIF→sendAnimation, static→sendPhoto)
