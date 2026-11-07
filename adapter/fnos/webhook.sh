# adapter/fnos/webhook.sh — fnOS (飞牛) inbound notification channel
#
# fnOS: 系统设置 → 系统通知 → 通知设置 → 新增机器人（钉钉 / 企业微信 / 飞书）
# 机器人地址填：
#   http://<nas-host>:6160/cgi-bin/router.sh/fnos?token=<FNOS_WEBHOOK_TOKEN>
#
# Payload shapes produced by those channels:
#   dingtalk / wecom  {"msgtype":"text","text":{"content":"..."}}
#   feishu            {"msg_type":"text","content":{"text":"..."}}
#   generic           {"title":"...","text":"...","content":"..."}
#
# Delivery: log the text, then relay it to every target in FNOS_NOTIFY_TO
# (space separated, "<platform>:<target>"), e.g.
#   FNOS_NOTIFY_TO="qqbot:private/<openid> telegram:<chat_id>"
# The HTTP answer is always success: fnOS treats a non-zero errcode by retrying
# the same alert forever, and a relay failure cannot be fixed by a retry.
#
# hush has no `local`: every variable here is prefixed _fn* to avoid clobbering
# the caller (router.sh) or the send helpers.

# _fnos_text <body> → message text on stdout (empty when no text field)
_fnos_text() {
	_fn_o="$(json_get "$1" text 2>/dev/null)" || _fn_o=""
	case "$_fn_o" in
		''|NOTFOUND|null) ;;
		"{"*)
			_fn_v="$(json_get "$_fn_o" content 2>/dev/null)" || _fn_v=""
			case "$_fn_v" in
				''|NOTFOUND|null) ;;
				*) printf '%s' "$_fn_v"; return 0 ;;
			esac
			;;
		*) printf '%s' "$_fn_o"; return 0 ;;
	esac
	_fn_o="$(json_get "$1" content 2>/dev/null)" || _fn_o=""
	case "$_fn_o" in
		''|NOTFOUND|null) ;;
		"{"*)
			_fn_v="$(json_get "$_fn_o" text 2>/dev/null)" || _fn_v=""
			case "$_fn_v" in
				''|NOTFOUND|null) ;;
				*) printf '%s' "$_fn_v"; return 0 ;;
			esac
			;;
		*) printf '%s' "$_fn_o"; return 0 ;;
	esac
	_fn_v="$(json_get "$1" msg 2>/dev/null)" || _fn_v=""
	case "$_fn_v" in
		''|NOTFOUND|null) ;;
		*) printf '%s' "$_fn_v"; return 0 ;;
	esac
	printf ''
}

# _fnos_relay <text> — best effort; one log line per configured target
_fnos_relay() {
	_fn_txt="$1"
	[ -n "${FNOS_NOTIFY_TO:-}" ] || { log_debug "fnos: FNOS_NOTIFY_TO empty, log only"; return 0; }
	for _fn_to in $FNOS_NOTIFY_TO; do
		_fn_pf="${_fn_to%%:*}"
		_fn_dst="${_fn_to#*:}"
		case "$_fn_pf" in
		qqbot)
			. "$_HB/adapter/qqbot/core.sh"
			. "$_HB/adapter/qqbot/message.sh"
			case "$_fn_dst" in
			private/*)
				_fn_id="${_fn_dst#private/}"
				if qqbot_message_send_c2c "$_fn_id" "$_fn_txt" >/dev/null 2>&1; then
					log_info "fnos→qqbot private $_fn_id OK"
				else
					log_err "fnos→qqbot private $_fn_id FAIL: $_ERROR"
				fi
				;;
			group/*)
				_fn_id="${_fn_dst#group/}"
				if qqbot_message_send_group "$_fn_id" "$_fn_txt" >/dev/null 2>&1; then
					log_info "fnos→qqbot group $_fn_id OK"
				else
					log_err "fnos→qqbot group $_fn_id FAIL: $_ERROR"
				fi
				;;
			*)
				log_warn "fnos: bad qqbot target '$_fn_dst' (want private/<openid> or group/<openid>)"
				;;
			esac
			;;
		telegram)
			[ -n "${_TG_SOURCED:-}" ] || . "$_HB/adapter/telegram/core.sh"
			_fn_body="$(json_obj chat_id "$_fn_dst" text "$_fn_txt")"
			if _tg_api sendMessage "$_fn_body" "fnos.tg" >/dev/null 2>&1; then
				log_info "fnos→telegram $_fn_dst OK"
			else
				log_err "fnos→telegram $_fn_dst FAIL: $_ERROR"
			fi
			;;
		*)
			log_warn "fnos: unknown target platform '$_fn_pf'"
			;;
		esac
	done
	return 0
}

# fnos_webhook <body> — entry called by router.sh; always returns 0
fnos_webhook() {
	_fn_raw="$1"
	case "$_fn_raw" in
		''|null)
			log_warn "fnos: empty body"
			return 0
			;;
	esac
	_fn_txt="$(_fnos_text "$_fn_raw")"
	[ -n "$_fn_txt" ] || _fn_txt="$(printf '%s' "$_fn_raw" | cut -c1-500)"
	# Keep one line per alert: fnOS bodies embed newlines in the content.
	_fn_one="$(printf '%s' "$_fn_txt" | awk 1 ORS=' ')"
	log_info "fnos: notify ← $(printf '%s' "$_fn_one" | cut -c1-300)"
	_fnos_relay "$_fn_txt"
	return 0
}
