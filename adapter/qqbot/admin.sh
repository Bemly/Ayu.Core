# adapter/qqbot/admin.sh — group commands: nickname bind / history
#
# The official API never exposes a member nickname: every event carries only a
# per-bot openid, and relays would otherwise show `qq#<first7>` forever. An
# admin can therefore teach the bot a display name:
#
#   @bot @someone 宝宝        bind the mentioned member
#   @bot 291A162 宝宝         bind by the 7-char prefix seen in relays
#   @bot 历史                 the last 5 messages, each with its id
#
# Latest binding wins, so a name can be rewritten without limit. Only openids
# listed in QQBOT_ADMINS (etc/config.sh) may bind; an entry may be a full
# openid or a ≥7-char prefix (group member openids are per-group, so an admin
# configured for one group is nobody in another).

. "$_HB/adapter/qqbot/handler.sh"

QQBOT_NICK_DIR="${QQBOT_NICK_DIR:-${_STATE_DIR:-$_HB/var/state}/qqbot-nick}"
QQBOT_HIST_DIR="${QQBOT_HIST_DIR:-${_STATE_DIR:-$_HB/var/state}/qqbot-hist}"
QQBOT_HIST_KEEP="${QQBOT_HIST_KEEP:-50}"   # lines kept per chat
QQBOT_HIST_SHOW="${QQBOT_HIST_SHOW:-5}"    # lines returned by 历史

# ---- nickname bindings ---------------------------------------------------

# qqbot_nick_file <group_openid> → path of the tab-separated <openid>\t<nick>
qqbot_nick_file() {
	printf '%s/%s' "$QQBOT_NICK_DIR" "$1"
}

# qqbot_nick_get <group_openid> <openid> → nickname, empty when unbound
qqbot_nick_get() {
	[ -n "$1" ] && [ -n "$2" ] || return 0
	_qng_f="$(qqbot_nick_file "$1")"
	[ -f "$_qng_f" ] || return 0
	awk -F '\t' -v id="$2" '$1 == id { print $2; exit }' "$_qng_f"
}

# qqbot_nick_set <group_openid> <openid> <nickname> — rewrite-or-add
qqbot_nick_set() {
	[ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 1
	mkdir -p "$QQBOT_NICK_DIR" 2>/dev/null
	_qns_f="$(qqbot_nick_file "$1")"
	_qns_t="$_qns_f.tmp.$$"
	if [ -f "$_qns_f" ]; then
		awk -F '\t' -v id="$2" '$1 != id' "$_qns_f" > "$_qns_t" || return 1
	else
		: > "$_qns_t" || return 1
	fi
	printf '%s\t%s\n' "$2" "$3" >> "$_qns_t" || return 1
	mv "$_qns_t" "$_qns_f"
}

# qqbot_nick_drop <group_openid> <openid>
qqbot_nick_drop() {
	_qnd_f="$(qqbot_nick_file "$1")"
	[ -f "$_qnd_f" ] || return 0
	awk -F '\t' -v id="$2" '$1 != id' "$_qnd_f" > "$_qnd_f.tmp.$$" \
		&& mv "$_qnd_f.tmp.$$" "$_qnd_f"
}

# ---- recent message log --------------------------------------------------

# qqbot_hist_append <group_openid> <msg_id> <openid> <text>
# One line per message: id \t openid \t text. Newlines/tabs are flattened so
# the file stays line-addressable by tail/awk.
qqbot_hist_append() {
	[ -n "$1" ] && [ -n "$2" ] || return 0
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

# ---- target resolution ---------------------------------------------------

# qqbot_resolve_openid <group_openid> <token> → full openid
# A token is either the full openid, or the 7-char prefix shown in relays. The
# prefix is resolved against bindings and the message log; an ambiguous prefix
# resolves to nothing (the caller answers "ambiguous").
qqbot_resolve_openid() {
	_qro_t="$2"
	[ -n "$_qro_t" ] || return 0
	case "$_qro_t" in *[!0-9A-Fa-f]*) return 0 ;; esac
	_qro_len="$(printf '%s' "$_qro_t" | wc -c)"
	if [ "$_qro_len" -ge 20 ]; then
		printf '%s' "$_qro_t"
		return 0
	fi
	_qro_nf="$(qqbot_nick_file "$1")"
	_qro_hf="$QQBOT_HIST_DIR/$1"
	_qro_c="$(
		{
			[ -f "$_qro_nf" ] && awk -F '\t' -v p="$_qro_t" 'index($1, p) == 1 { print $1 }' "$_qro_nf"
			[ -f "$_qro_hf" ] && awk -F '\t' -v p="$_qro_t" 'index($2, p) == 1 { print $2 }' "$_qro_hf"
		} | sort -u
	)"
	_qro_n="$(printf '%s\n' "$_qro_c" | grep -c . 2>/dev/null)"
	[ "$_qro_n" = "1" ] && printf '%s' "$_qro_c"
	return 0
}

# ---- commands ------------------------------------------------------------

qqbot_admin_usage() {
	printf '用法：
@bot @某人 昵称   绑定
@bot 291A162 昵称  按7位id绑定
@bot 历史          最近5条'
}

qqbot_admin_history() {
	_qah_d="$1" _qah_gid="$2"
	_qah_lines="$(qqbot_hist_tail "$_qah_gid" "$QQBOT_HIST_SHOW")"
	if [ -z "$_qah_lines" ]; then
		qqbot_reply_event "$_qah_d" "还没有记录"
		return 0
	fi
	_qah_txt="最近 $QQBOT_HIST_SHOW 条：
$(printf '%s\n' "$_qah_lines" | awk -F '\t' -v nkdir="$QQBOT_NICK_DIR" -v gid="$_qah_gid" '
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
	qqbot_reply_event "$_qah_d" "$_qah_txt"
}

# qqbot_admin_handle <event_type> <raw d> <group_openid> <openid>
# Returns 0 when the event was consumed as a command (so it must not be
# relayed by sync), 1 when it is an ordinary message.
qqbot_admin_handle() {
	_qam_evt="$1" _qam_d="$2" _qam_gid="$3" _qam_uid="$4"
	[ -n "$_qam_gid" ] || return 1
	case "$_qam_evt" in
		GROUP_AT_MESSAGE_CREATE|AT_MESSAGE_CREATE) : ;;
		*) return 1 ;;
	esac
	_qam_c="$(json_get "$_qam_d" content 2>/dev/null)" || _qam_c=""
	case "$_qam_c" in ''|NOTFOUND|null) return 1 ;; esac

	# mentions in order: the bot comes first (the message is an @-message),
	# any further one is the bind target
	_qam_m="$(printf '%s' "$_qam_c" | grep -o '<@[A-Za-z0-9!]\{8,\}>' \
		| sed 's/^<@//; s/>$//; s/^!//')"
	_qam_rest="$(printf '%s' "$_qam_c" | sed 's/<@[A-Za-z0-9!]\{8,\}>//g' \
		| sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g')"
	[ -n "$_qam_rest" ] || return 1

	case "$_qam_rest" in
		历史|/history|history)
			qqbot_admin_history "$_qam_d" "$_qam_gid"
			return 0
			;;
	esac

	# target: second mention, else the first word (7-char id form)
	_qam_n="$(printf '%s\n' "$_qam_m" | grep -c . 2>/dev/null)"
	[ -n "$_qam_n" ] || _qam_n=0
	if [ "$_qam_n" -ge 2 ]; then
		_qam_tgt="$(printf '%s\n' "$_qam_m" | sed -n 2p)"
		_qam_nick="$_qam_rest"
	else
		_qam_tgt="${_qam_rest%% *}"
		[ "$_qam_tgt" = "$_qam_rest" ] && return 1   # one word: not a bind
		_qam_nick="${_qam_rest#* }"
	fi
	# neither a 32-char openid nor a short hex id → ordinary message
	case "$_qam_tgt" in *[!0-9A-Fa-f]*) return 1 ;; esac

	if ! qqbot_is_admin "$_qam_uid"; then
		qqbot_reply_event "$_qam_d" "只有管理员能绑定昵称"
		return 0
	fi

	_qam_nick="$(printf '%s' "$_qam_nick" | tr -d '<>' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	if [ -z "$_qam_nick" ]; then
		qqbot_reply_event "$_qam_d" "$(qqbot_admin_usage)"
		return 0
	fi

	_qam_oid="$(qqbot_resolve_openid "$_qam_gid" "$_qam_tgt")"
	if [ -z "$_qam_oid" ]; then
		qqbot_reply_event "$_qam_d" "找不到 $_qam_tgt 对应的成员（让他先发一句话，或用完整 openid）"
		return 0
	fi
	if ! qqbot_nick_set "$_qam_gid" "$_qam_oid" "$_qam_nick"; then
		qqbot_reply_event "$_qam_d" "绑定失败：无法写入映射"
		return 1
	fi
	qqbot_reply_event "$_qam_d" "已绑定 qq#$(printf '%s' "$_qam_oid" | cut -c1-7) = $_qam_nick"
	log_info "qqbot: admin $_qam_uid bound $(printf '%s' "$_qam_oid" | cut -c1-7) = $_qam_nick"
	return 0
}
