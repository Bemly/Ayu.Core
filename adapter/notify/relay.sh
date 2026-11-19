#!/bin/sh
# adapter/notify/relay.sh — event relay for the notify gateway (v2)
#
# Wired in etc/rules BEFORE the catch-all sync rule:
#   *|adapter/notify/relay.sh|notify_relay_button
#
# Returns 0 when the event was relayed (or deliberately swallowed), 2 when it
# is not a notify event — dispatch.sh treats 2 as "keep matching", so the sync
# rule behind it still receives ordinary messages untouched.
#
# What gets relayed
#   QQ  INTERACTION_CREATE, every sub-type:
#         11 message button      → event=button
#         12 quick menu          → event=menu
#         13 message feedback    → event=feedback
#         14 clear session       → event=clear_session
#         15 story enter/quit    → event=story
#         16 story action        → event=story_action
#         *                      → event=interaction
#   TG  callback_query          → event=button / event=menu (data "menu:" prefix)
#   DC  MESSAGE_COMPONENT       → event=button, MODAL_SUBMIT → event=modal
#
# Key resolution
#   A button carries its own key ("…&_k=<hex>"). Every other interaction has no
#   payload of its own, so it falls back to the newest key stored for that chat
#   at send time (var/state/notify-cb-last/<platform>-<chat>). The relayed
#   payload announces this with "fallback": true so the caller can tell the two
#   apart. Set NOTIFY_RELAY_FALLBACK_LAST=0 to disable.
#
# Outbound payload (unchanged core, new fields appended):
#   {
#     "event":        "button" | "menu" | "feedback" | "clear_session"
#                   | "story" | "story_action" | "modal" | "interaction",
#     "platform":     "qqbot" | "telegram" | "discord",
#     "scene":        "group" | "c2c" | "chat" | "channel",
#     "chat":         "<group_openid|chat_id|channel_id>",
#     "user":         "<member_openid|user_id>",
#     "button_id":    "<id>",
#     "data":         "<button data with _k stripped>",
#     "message_id":   "<message the button belonged to>",
#     "interaction_id": "<platform interaction id>",
#     "interaction_type": <raw platform type>,
#     "fallback":     true | false
#   }

. "$_HB/lib/core.sh"
. "$_HB/lib/log.sh"
. "$_HB/lib/http.sh"

_NOTIFY_CB_DIR="${_STATE_DIR:-$_HB/var/state}/notify-cb"
_NOTIFY_LAST_DIR="${_STATE_DIR:-$_HB/var/state}/notify-cb-last"
_NOTIFY_HTTP_TIMEOUT="${NOTIFY_HTTP_TIMEOUT:-4}"
_NOTIFY_RELAY_FALLBACK_LAST="${NOTIFY_RELAY_FALLBACK_LAST:-1}"

# ---- text helpers ------------------------------------------------------

# _notify_relay_key <text> → the _k=<hex> value, "" when absent
_notify_relay_key() {
	case "$1" in
		*_k=*) : ;;
		*) return 1 ;;
	esac
	_nrk_t="${1#*_k=}"
	_nrk_k="${_nrk_t%%&*}"
	_nrk_k="${_nrk_k%% *}"
	case "$_nrk_k" in
		''|*[!0-9A-Za-z]*) return 1 ;;
	esac
	printf '%s' "$_nrk_k"
}

# _notify_relay_data <text> → button data with _k stripped
_notify_relay_data() {
	_nrd_t="$1"
	_nrd_t="$(printf '%s' "$_nrd_t" | sed 's/&_k=[0-9A-Za-z]*//g; s/_k=[0-9A-Za-z]*&//g; s/^_k=[0-9A-Za-z]*$//')"
	printf '%s' "$_nrd_t"
}

# _notify_relay_pick <text> <field> → field value from "k=v k=v" event text
_notify_relay_pick() {
	_nrp_t=" $1"
	_nrp_k="$2"
	case "$_nrp_t" in
		*" $_nrp_k="*) : ;;
		*) return 1 ;;
	esac
	_nrp_v="${_nrp_t#* $_nrp_k=}"
	_nrp_v="${_nrp_v%% *}"
	printf '%s' "$_nrp_v"
}

# _notify_relay_jget <json> <key> → value or ""
_notify_relay_jget() {
	_nrj_v="$(json_get "$1" "$2" 2>/dev/null)" || _nrj_v=""
	case "$_nrj_v" in NOTFOUND|null) _nrj_v="" ;; esac
	printf '%s' "$_nrj_v"
}

# _notify_relay_last_key <platform> <chat> → key or ""
_notify_relay_last_key() {
	_nrl_f="$(printf '%s-%s' "$1" "$2" | tr -c 'A-Za-z0-9_.-' '_')"
	[ -f "$_NOTIFY_LAST_DIR/$_nrl_f" ] || return 0
	cat "$_NOTIFY_LAST_DIR/$_nrl_f" 2>/dev/null
}

# _notify_relay_event_name <platform> <raw type> <text> → event name
_notify_relay_event_name() {
	case "$1" in
		qqbot)
			case "$2" in
				11) printf 'button' ;;
				12) printf 'menu' ;;
				13) printf 'feedback' ;;
				14) printf 'clear_session' ;;
				15) printf 'story' ;;
				16) printf 'story_action' ;;
				'') printf 'interaction' ;;
				*)  printf 'interaction' ;;
			esac
			;;
		telegram)
			case "$3" in
				menu:*) printf 'menu' ;;
				*)      printf 'button' ;;
			esac
			;;
		discord)
			case "$2" in
				5) printf 'modal' ;;
				*) printf 'button' ;;
			esac
			;;
		*) printf 'interaction' ;;
	esac
}

# ---- entry -------------------------------------------------------------

# notify_relay_button <platform> <event> <uid> <text> <raw>
notify_relay_button() {
	_nrb_pf="$1" _nrb_evt="$2" _nrb_uid="$3" _nrb_txt="$4" _nrb_raw="$5"

	case "$_nrb_evt" in
		interaction|callback|component|modal_submit|menu) : ;;
		*) return 2 ;;
	esac

	# ---- per-platform extraction ----
	_nrb_id="" _nrb_data="" _nrb_type="" _nrb_iid="" _nrb_scene="" _nrb_chat=""
	_nrb_user="$_nrb_uid" _nrb_msg=""
	case "$_nrb_pf" in
		qqbot)
			_nrb_type="$(_notify_relay_jget "$_nrb_raw" type)"
			[ -n "$_nrb_type" ] || \
				_nrb_type="$(_notify_relay_jget "$(json_get "$_nrb_raw" data 2>/dev/null)" type)"
			_nrb_iid="$(_notify_relay_jget "$_nrb_raw" id)"
			# Simplified payloads omit d.type; a button= in the event text is an
			# unambiguous 11 (message button), which is what callers expect.
			[ -n "$_nrb_type" ] || case "$_nrb_txt" in
				*" button="*) _nrb_type=11 ;;
			esac
			_nrb_scene="$(_notify_relay_jget "$_nrb_raw" scene)"
			case "$_nrb_scene" in ''|NOTFOUND|null) _nrb_scene="group" ;; esac
			_nrb_chat="$(_notify_relay_jget "$_nrb_raw" group_openid)"
			[ -n "$_nrb_chat" ] || _nrb_chat="$(_notify_relay_jget "$_nrb_raw" user_openid)"
			_nrb_user="$(_notify_relay_jget "$_nrb_raw" group_member_openid)"
			[ -n "$_nrb_user" ] || _nrb_user="$_nrb_uid"
			# resolved is authoritative; older payloads put button_data at data.*
			_nrb_res="$(_notify_relay_jget "$_nrb_raw" resolved)"
			[ -n "$_nrb_res" ] || _nrb_res="$(_notify_relay_jget "$(json_get "$_nrb_raw" data 2>/dev/null)" resolved)"
			_nrb_id="$(_notify_relay_jget "$_nrb_res" button_id)"
			_nrb_data="$(_notify_relay_jget "$_nrb_res" button_data)"
			[ -n "$_nrb_data" ] || _nrb_data="$(_notify_relay_jget "$(json_get "$_nrb_raw" data 2>/dev/null)" button_data)"
			_nrb_msg="$(_notify_relay_jget "$_nrb_res" message_id)"
			# event text is the fallback when the raw body is unusual
			[ -n "$_nrb_id" ] || _nrb_id="$(_notify_relay_pick "$_nrb_txt" button)"
			[ -n "$_nrb_data" ] || _nrb_data="$(_notify_relay_pick "$_nrb_txt" data)"
			[ -n "$_nrb_msg" ] || _nrb_msg="$(_notify_relay_pick "$_nrb_txt" msg)"
			;;
		telegram)
			_nrb_iid="$(_notify_relay_jget "$_nrb_raw" id)"
			_nrb_scene="chat"
			_nrb_chat="$(_notify_relay_jget "$(json_get "$_nrb_raw" message 2>/dev/null)" chat_id)"
			_nrb_user="$(_notify_relay_jget "$(json_get "$_nrb_raw" from 2>/dev/null)" id)"
			[ -n "$_nrb_user" ] || _nrb_user="$_nrb_uid"
			_nrb_msg="$(_notify_relay_jget "$(json_get "$_nrb_raw" message 2>/dev/null)" message_id)"
			case "$_nrb_txt" in
				*'|'*) _nrb_id="${_nrb_txt%%|*}"; _nrb_data="${_nrb_txt#*|}" ;;
				*)     _nrb_data="$_nrb_txt" ;;
			esac
			# Stop the client-side spinner — mandatory for callback_query.
			[ -n "$_nrb_iid" ] && {
				. "$_HB/adapter/telegram/message.sh" 2>/dev/null
				tg_answerCallbackQuery "$_nrb_iid" "" >/dev/null 2>&1
			}
			;;
		discord)
			_nrb_type="$(_notify_relay_jget "$_nrb_raw" type)"
			_nrb_iid="$(_notify_relay_jget "$_nrb_raw" id)"
			_nrb_scene="channel"
			_nrb_chat="$(_notify_relay_jget "$_nrb_raw" channel_id)"
			_nrb_user="$(_notify_relay_jget "$(json_get "$_nrb_raw" member 2>/dev/null)" user)"
			[ -n "$_nrb_user" ] || _nrb_user="$_nrb_uid"
			case "$_nrb_txt" in
				*'|'*) _nrb_id="${_nrb_txt%%|*}"; _nrb_data="${_nrb_txt#*|}" ;;
				*)     _nrb_data="$_nrb_txt" ;;
			esac
			_nrb_msg="$(_notify_relay_jget "$(json_get "$_nrb_raw" message 2>/dev/null)" id)"
			[ -n "$_nrb_msg" ] || _nrb_msg="$(_notify_relay_jget "$_nrb_raw" message_id)"
			;;
	esac

	# ---- key resolution: own _k first, then the chat's newest key --------
	_nrb_key="$(_notify_relay_key "$_nrb_data")" || _nrb_key=""
	_nrb_fallback=false
	if [ -z "$_nrb_key" ]; then
		[ "$_NOTIFY_RELAY_FALLBACK_LAST" = "1" ] || return 2
		_nrb_key="$(_notify_relay_last_key "$_nrb_pf" "$_nrb_chat")"
		[ -n "$_nrb_key" ] || return 2
		_nrb_fallback=true
	fi

	_nrb_url=""
	[ -f "$_NOTIFY_CB_DIR/$_nrb_key" ] && _nrb_url="$(cat "$_NOTIFY_CB_DIR/$_nrb_key" 2>/dev/null)"
	if [ -z "$_nrb_url" ]; then
		log_warn "notify: relay key $_nrb_key has no callback url (expired?)"
		return 0
	fi

	_nrb_event="$(_notify_relay_event_name "$_nrb_pf" "$_nrb_type" "$_nrb_data")"
	_nrb_clean="$(_notify_relay_data "$_nrb_data")"

	_nrb_payload="$(json_obj \
		event "$_nrb_event" \
		platform "$_nrb_pf" \
		scene "$_nrb_scene" \
		chat "$_nrb_chat" \
		user "$_nrb_user" \
		button_id "$_nrb_id" \
		data "$_nrb_clean" \
		message_id "$_nrb_msg" \
		interaction_id "$_nrb_iid" \
		interaction_type "${_nrb_type:-0}" \
		fallback "$_nrb_fallback")"

	_HTTP_TIMEOUT="$_NOTIFY_HTTP_TIMEOUT"
	if http_post "$_nrb_url" "$_nrb_payload" "Content-Type: application/json" >/dev/null 2>&1; then
		log_info "notify: relay ok key=$_nrb_key pf=$_nrb_pf event=$_nrb_event id=${_nrb_id:-none} fb=$_nrb_fallback"
	else
		log_err "notify: relay failed key=$_nrb_key url=$_nrb_url: $_ERROR"
	fi
	return 0
}
