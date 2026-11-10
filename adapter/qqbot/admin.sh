# adapter/qqbot/admin.sh — group commands: history + platform nickname cache
#
# Every event carries `author.username` next to the per-bot openid, but the
# platform leaves it empty for many bots, so relays would otherwise only ever
# show `qq#<first7>`. Whatever the platform does send is cached per group here
# (var/state/qqbot-nick-auto) so that mentions and relays keep the name on the
# messages that arrive without one. There is no binding table: names cannot be
# set by hand, only taken from the platform.
#
#   @bot 历史                 the last 5 messages, each with its id

. "$_HB/adapter/qqbot/handler.sh"

# Nicknames the platform itself reports, one `<openid>\t<nick>` line per member.
QQBOT_NICK_AUTO_DIR="${QQBOT_NICK_AUTO_DIR:-${_STATE_DIR:-$_HB/var/state}/qqbot-nick-auto}"
QQBOT_HIST_DIR="${QQBOT_HIST_DIR:-${_STATE_DIR:-$_HB/var/state}/qqbot-hist}"
QQBOT_HIST_KEEP="${QQBOT_HIST_KEEP:-50}"   # lines kept per chat
QQBOT_HIST_SHOW="${QQBOT_HIST_SHOW:-5}"    # lines returned by 历史

# qqbot_gid_ok <group_openid> → 0 when the id is safe to use as a filename
# group_openid comes from the event JSON; every path below is "$dir/$gid", so a
# value carrying '/' or '..' would walk out of the state dir. handler.sh already
# constrains its own paths — this file must guard the ones it builds.
qqbot_gid_ok() {
	case "$1" in ''|*[!0-9A-Za-z_-]*) return 1 ;; esac
	[ "${#1}" -le 64 ] || return 1
	return 0
}

# ---- platform-reported nicknames ----------------------------------------

# qqbot_nick_auto_file <group_openid>
qqbot_nick_auto_file() {
	qqbot_gid_ok "$1" || return 1
	printf '%s/%s' "$QQBOT_NICK_AUTO_DIR" "$1"
}

# qqbot_nick_auto_get <group_openid> <openid> → cached platform nickname
qqbot_nick_auto_get() {
	[ -n "$1" ] && [ -n "$2" ] || return 0
	_qnag_f="$(qqbot_nick_auto_file "$1")" || return 0
	[ -f "$_qnag_f" ] || return 0
	awk -F '\t' -v id="$2" '$1 == id { print $2; exit }' "$_qnag_f"
}

# qqbot_nick_auto_set <group_openid> <openid> <nickname>
# Only rewrites when the value actually changed: events arrive per message and
# an unconditional write would churn the state dir on every line of chat.
qqbot_nick_auto_set() {
	[ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 1
	[ "$(qqbot_nick_auto_get "$1" "$2")" = "$3" ] && return 0
	mkdir -p "$QQBOT_NICK_AUTO_DIR" 2>/dev/null
	_qnas_f="$(qqbot_nick_auto_file "$1")" || return 1
	_qnas_t="$_qnas_f.tmp.$$"
	if [ -f "$_qnas_f" ]; then
		awk -F '\t' -v id="$2" '$1 != id' "$_qnas_f" > "$_qnas_t" || return 1
	else
		: > "$_qnas_t" || return 1
	fi
	printf '%s\t%s\n' "$2" "$3" >> "$_qnas_t" || return 1
	mv "$_qnas_t" "$_qnas_f"
}

# ---- recent message log --------------------------------------------------

# qqbot_hist_append <group_openid> <msg_id> <openid> <text>
# One line per message: id \t openid \t text. Newlines/tabs are flattened so
# the file stays line-addressable by tail/awk.
qqbot_hist_append() {
	[ -n "$1" ] && [ -n "$2" ] || return 0
	qqbot_gid_ok "$1" || return 0
	mkdir -p "$QQBOT_HIST_DIR" 2>/dev/null
	_qha_f="$QQBOT_HIST_DIR/$1"
	_qha_t="$(printf '%s' "$4" | tr '\t\r\n' '   ')"
	printf '%s\t%s\t%s\n' "$2" "$3" "$_qha_t" >> "$_qha_f" || return 0
	_qha_n="$(wc -l < "$_qha_f" 2>/dev/null)"
	case "$_qha_n" in ''|*[!0-9]*) return 0 ;; esac
	if [ "$_qha_n" -gt "$QQBOT_HIST_KEEP" ]; then
		tail -n "$QQBOT_HIST_KEEP" "$_qha_f" > "$_qha_f.tmp.$$" \
			&& mv "$_qha_f.tmp.$$" "$_qha_f"
	fi
}

# qqbot_hist_tail <group_openid> <n> — oldest → newest
qqbot_hist_tail() {
	qqbot_gid_ok "$1" || return 0
	_qht_f="$QQBOT_HIST_DIR/$1"
	[ -f "$_qht_f" ] || return 0
	tail -n "$2" "$_qht_f"
}

# ---- admin check ---------------------------------------------------------

# qqbot_is_admin <openid> — exact match, or prefix match for short entries
qqbot_is_admin() {
	_qia_id="$1"
	[ -n "$_qia_id" ] || return 1
	for _qia_a in ${QQBOT_ADMINS:-}; do
		[ "$_qia_a" = "$_qia_id" ] && return 0
		_qia_len="$(printf '%s' "$_qia_a" | wc -c)"
		if [ "$_qia_len" -ge 7 ] && [ "$_qia_len" -lt 20 ]; then
			case "$_qia_id" in "$_qia_a"*) return 0 ;; esac
		fi
	done
	return 1
}

# ---- commands ------------------------------------------------------------

qqbot_admin_history() {
	_qah_d="$1" _qah_gid="$2" _qah_mode="${3:-passive}"
	_qah_lines="$(qqbot_hist_tail "$_qah_gid" "$QQBOT_HIST_SHOW")"
	if [ -z "$_qah_lines" ]; then
		qqbot_reply_event "$_qah_d" "还没有记录" "$_qah_mode"
		return 0
	fi
	_qah_txt="最近 $QQBOT_HIST_SHOW 条：
$(printf '%s\n' "$_qah_lines" | awk -F '\t' -v nkdir="$QQBOT_NICK_AUTO_DIR" -v gid="$_qah_gid" '
	{
		i++
		name = ""
		f = nkdir "/" gid
		while ((getline line < f) > 0) {
			split(line, kv, "\t")
			if (kv[1] == $2) { name = kv[2]; break }
		}
		close(f)
		if (name == "") name = "qq#" substr($2, 1, 7)
		printf "%d. %s\n   id=%s\n   %s\n", i, name, $1, $3
	}')"
	qqbot_reply_event "$_qah_d" "$_qah_txt" "$_qah_mode"
}

# qqbot_admin_handle <event_type> <raw d> <group_openid> <openid>
# Returns 0 when the event was consumed as a command (so it must not be
# relayed by sync), 1 when it is an ordinary message.
qqbot_admin_handle() {
	_qam_evt="$1" _qam_d="$2" _qam_gid="$3" _qam_uid="$4"
	[ -n "$_qam_gid" ] || return 1
	# An @-message is normally delivered as GROUP_AT_MESSAGE_CREATE, but a bot
	# subscribed to the full group stream receives the same message under
	# GROUP_MESSAGE_CREATE instead — QQ sends one type, not both. Accept either
	# and verify below that the bot itself is the leading mention, so ordinary
	# chatter never looks like a command.
	# A full-stream GROUP_MESSAGE_CREATE cannot be answered with a passive reply
	# (QQ rejects the msg_id echo), so commands arriving that way must use an
	# active message. AT events keep the passive form.
	_qam_mode="passive"
	case "$_qam_evt" in
		GROUP_AT_MESSAGE_CREATE|AT_MESSAGE_CREATE) _qam_at=1 ;;
		GROUP_MESSAGE_CREATE) _qam_at=0 _qam_mode="active" ;;
		*) return 1 ;;
	esac
	_qam_c="$(json_get "$_qam_d" content 2>/dev/null)" || _qam_c=""
	case "$_qam_c" in ''|NOTFOUND|null) return 1 ;; esac
	# mentions arrive HTML-escaped (`\u003c@openid\u003e`); decode before parsing
	_qam_c="$(utf8_decode "$_qam_c")"

	_qam_m="$(printf '%s' "$_qam_c" | grep -o '<@[A-Za-z0-9!]\{8,\}>' \
		| sed 's/^<@//; s/>$//; s/^!//')"
	_qam_rest="$(printf '%s' "$_qam_c" | sed 's/<@[A-Za-z0-9!]\{8,\}>//g' \
		| sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g')"
	# full-stream message: only an @-message aimed at the bot is a command.
	# QQBOT_BOT_OPENID pins that to the bot's own openid; when unset, any
	# leading mention is accepted and the text itself must still parse.
	if [ "$_qam_at" = 0 ]; then
		[ -n "$_qam_m" ] || return 1
		if [ -n "${QQBOT_BOT_OPENID:-}" ]; then
			[ "$(printf '%s\n' "$_qam_m" | sed -n 1p)" = "$QQBOT_BOT_OPENID" ] || return 1
		fi
	fi
	[ -n "$_qam_rest" ] || return 1

	case "$_qam_rest" in
		历史|/history|history)
			# history leaks message bodies plus every member openid, so it is
			# admin-only.
			if ! qqbot_is_admin "$_qam_uid"; then
				qqbot_reply_event "$_qam_d" "只有管理员能查看历史" "$_qam_mode"
				return 0
			fi
			qqbot_admin_history "$_qam_d" "$_qam_gid" "$_qam_mode"
			return 0
			;;
	esac
	return 1
}
