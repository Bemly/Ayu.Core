# adapter/qqbot/webhook.sh — QQ Bot webhook entry
#
# Two payload shapes arrive on the same callback URL:
#   op=13  callback address validation → answer {plain_token, signature}
#   op=0   event dispatch             → answer {"op":12,"d":{}} (ACK)
#
# Signature: Ed25519 over (X-Signature-Timestamp || raw body), verified with
# the key derived from AppSecret. Enforcement is controlled by
# QQBOT_VERIFY_SIG (auto/1/0); the ?token= WEBHOOK_SECRET check in router.sh
# always runs first.
#
# Set _QQBOT_STATUS to the CGI status line to emit; the body goes to stdout.

. "$_HB/adapter/qqbot/core.sh"
. "$_HB/adapter/qqbot/sign.sh"
. "$_HB/adapter/qqbot/message.sh"

QQBOT_DEDUP_FILE="${QQBOT_DEDUP_FILE:-${_STATE_DIR:-$_HB/var/state}/qqbot-dedup}"
QQBOT_DEDUP_MAX="${QQBOT_DEDUP_MAX:-500}"

_QQBOT_STATUS="200 OK"

# The CGI wrapper cannot see this variable: it runs the handler in a $(...)
# subshell. QQBOT_STATUS_FILE lets the status line travel back out-of-band.
_qqbot_set_status() {
	_QQBOT_STATUS="$1"
	[ -n "${QQBOT_STATUS_FILE:-}" ] && printf '%s' "$1" >"$QQBOT_STATUS_FILE" 2>/dev/null
	return 0
}

# ---- event dedup --------------------------------------------------------
# QQ retries a callback until it gets a 2xx ACK; the same event id may show up
# again after a slow response. Routing tables only — no message bodies.

qqbot_seen() {
	[ -f "$QQBOT_DEDUP_FILE" ] || return 1
	grep -Fqx -- "$1" "$QQBOT_DEDUP_FILE" 2>/dev/null
}

qqbot_remember() {
	[ -n "$1" ] || return 0
	mkdir -p "$(dirname "$QQBOT_DEDUP_FILE")" 2>/dev/null
	printf '%s\n' "$1" >>"$QQBOT_DEDUP_FILE" 2>/dev/null || return 0
	_qdtot="$(wc -l <"$QQBOT_DEDUP_FILE" 2>/dev/null | tr -d ' ')"
	case "$_qdtot" in ''|*[!0-9]*) return 0 ;; esac
	if [ "$_qdtot" -gt "$QQBOT_DEDUP_MAX" ]; then
		tail -n "$QQBOT_DEDUP_MAX" "$QQBOT_DEDUP_FILE" >"$QQBOT_DEDUP_FILE.tmp.$$" 2>/dev/null &&
			mv "$QQBOT_DEDUP_FILE.tmp.$$" "$QQBOT_DEDUP_FILE" 2>/dev/null
	fi
	return 0
}

# ---- op=13 callback validation -----------------------------------------

qqbot_webhook_validate() {
	_qv_d="$(json_get "$1" d 2>/dev/null)" || {
		_ERROR="qqbot: op=13 without d"
		_qqbot_set_status "400 Bad Request"
		return 1
	}
	_qv_tok="$(json_get "$_qv_d" plain_token 2>/dev/null)" || _qv_tok=""
	_qv_ts="$(json_get "$_qv_d" event_ts 2>/dev/null)" || _qv_ts=""
	if [ -z "$_qv_tok" ] || [ -z "$_qv_ts" ]; then
		_ERROR="qqbot: op=13 missing plain_token/event_ts"
		_qqbot_set_status "400 Bad Request"
		return 1
	fi
	_qv_f="/tmp/qqbot-sign.$$"
	printf '%s%s' "$_qv_ts" "$_qv_tok" >"$_qv_f" || {
		_ERROR="qqbot: cannot stage signing payload"
		_qqbot_set_status "500 Internal Server Error"
		return 1
	}
	_qv_sig="$(qqbot_ed_sign "$_qv_f")"
	_qv_rc=$?
	rm -f "$_qv_f"
	if [ $_qv_rc -ne 0 ]; then
		_qqbot_set_status "500 Internal Server Error"
		return 1
	fi
	log_info "qqbot: callback url validated (event_ts=$_qv_ts)"
	printf '{"plain_token":"%s","signature":"%s"}' "$_qv_tok" "$_qv_sig"
	return 0
}

# ---- event dispatch (op=0) ---------------------------------------------

qqbot_webhook_event() {
	_qe_body="$1" _qe_sig="$2" _qe_ts="$3"

	if qqbot_signature_enabled; then
		if [ -z "$_qe_sig" ] || [ -z "$_qe_ts" ]; then
			_ERROR="qqbot: missing X-Signature-Ed25519 / -Timestamp"
			_qqbot_set_status "401 Unauthorized"
			return 1
		fi
		_qe_f="/tmp/qqbot-verify.$$"
		printf '%s%s' "$_qe_ts" "$_qe_body" >"$_qe_f" || {
			_ERROR="qqbot: cannot stage verify payload"
			_qqbot_set_status "500 Internal Server Error"
			return 1
		}
		qqbot_ed_verify "$_qe_f" "$_qe_sig"
		_qe_rc=$?
		rm -f "$_qe_f"
		if [ $_qe_rc -ne 0 ]; then
			_ERROR="qqbot: callback signature mismatch"
			_qqbot_set_status "401 Unauthorized"
			return 1
		fi
	fi

	_qe_t="$(json_get "$_qe_body" t 2>/dev/null)" || _qe_t=""
	_qe_id="$(json_get "$_qe_body" id 2>/dev/null)" || _qe_id=""
	_qe_d="$(json_get "$_qe_body" d 2>/dev/null)" || _qe_d=""

	if [ -z "$_qe_t" ]; then
		# Malformed payload: retrying cannot fix it, so ACK and move on.
		log_warn "qqbot: event without t (len=${#_qe_body})"
		printf '{"op":12,"d":{}}'
		return 0
	fi

	if [ -n "$_qe_id" ] && qqbot_seen "$_qe_id"; then
		log_debug "qqbot: duplicate event $_qe_id"
		printf '{"op":12,"d":{}}'
		return 0
	fi
	qqbot_remember "$_qe_id"

	qqbot_handle_event "$_qe_t" "$_qe_d" "$_qe_body"
	_qh_rc=$?
	if [ $_qh_rc -ne 0 ]; then
		# Handler failed: still ACK. A retry would replay side effects, and
		# the failure is already in the log with its _ERROR.
		printf '{"op":12,"d":{}}'
		return 0
	fi
	printf '{"op":12,"d":{}}'
	return 0
}

# ---- event → dispatch ---------------------------------------------------

# qqbot_handle_event <t> <d> <raw>
qqbot_handle_event() {
	_qh_t="$1" _qh_d="$2"

	case "$_qh_t" in
		GROUP_AT_MESSAGE_CREATE|GROUP_MESSAGE_CREATE)
			_qh_a="$(json_get "$_qh_d" author 2>/dev/null)" || _qh_a=""
			_qh_gid="$(json_get "$_qh_d" group_openid 2>/dev/null)" || _qh_gid=""
			_qh_uid="$(json_get "$_qh_a" member_openid 2>/dev/null)" || _qh_uid=""
			_qh_bot="$(json_get "$_qh_a" bot 2>/dev/null)" || _qh_bot="false"
			_qh_txt="$(json_get "$_qh_d" content 2>/dev/null)" || _qh_txt=""
			[ "$_qh_bot" = "true" ] && return 0
			log_info "qqbot: group $_qh_gid ← $_qh_uid: $_qh_txt"
			dispatch "qqbot" "group_message" "$_qh_uid" "$_qh_txt" "$_qh_d"
			;;
		C2C_MESSAGE_CREATE)
			_qh_a="$(json_get "$_qh_d" author 2>/dev/null)" || _qh_a=""
			_qh_uid="$(json_get "$_qh_a" user_openid 2>/dev/null)" || _qh_uid=""
			_qh_txt="$(json_get "$_qh_d" content 2>/dev/null)" || _qh_txt=""
			log_info "qqbot: c2c ← $_qh_uid: $_qh_txt"
			dispatch "qqbot" "c2c_message" "$_qh_uid" "$_qh_txt" "$_qh_d"
			;;
		AT_MESSAGE_CREATE|MESSAGE_CREATE)
			_qh_a="$(json_get "$_qh_d" author 2>/dev/null)" || _qh_a=""
			_qh_uid="$(json_get "$_qh_a" id 2>/dev/null)" || _qh_uid=""
			_qh_bot="$(json_get "$_qh_a" bot 2>/dev/null)" || _qh_bot="false"
			_qh_txt="$(json_get "$_qh_d" content 2>/dev/null)" || _qh_txt=""
			[ "$_qh_bot" = "true" ] && return 0
			dispatch "qqbot" "channel_message" "$_qh_uid" "$_qh_txt" "$_qh_d"
			;;
		DIRECT_MESSAGE_CREATE)
			_qh_a="$(json_get "$_qh_d" author 2>/dev/null)" || _qh_a=""
			_qh_uid="$(json_get "$_qh_a" id 2>/dev/null)" || _qh_uid=""
			_qh_txt="$(json_get "$_qh_d" content 2>/dev/null)" || _qh_txt=""
			dispatch "qqbot" "direct_message" "$_qh_uid" "$_qh_txt" "$_qh_d"
			;;
		INTERACTION_CREATE)
			_qh_uid="$(json_get "$_qh_d" id 2>/dev/null)" || _qh_uid=""
			dispatch "qqbot" "interaction" "$_qh_uid" "interaction:$_qh_t" "$_qh_d"
			;;
		MESSAGE_REACTION_ADD|MESSAGE_REACTION_REMOVE|MESSAGE_REACTION_REMOVE_ALL)
			_qh_uid="$(json_get "$_qh_d" user_id 2>/dev/null)" || _qh_uid=""
			dispatch "qqbot" "reaction" "$_qh_uid" "reaction:$_qh_t" "$_qh_d"
			;;
		GROUP_ADD_ROBOT|GROUP_DEL_ROBOT|GROUP_MSG_REJECT|GROUP_MSG_RECEIVE)
			_qh_gid="$(json_get "$_qh_d" group_openid 2>/dev/null)" || _qh_gid=""
			_qh_uid="$(json_get "$_qh_d" op_member_openid 2>/dev/null)" || _qh_uid=""
			log_info "qqbot: $_qh_t group=$_qh_gid op=$_qh_uid"
			dispatch "qqbot" "group_event" "$_qh_uid" "$_qh_t:$_qh_gid" "$_qh_d"
			;;
		FRIEND_ADD|FRIEND_DEL|C2C_MSG_REJECT|C2C_MSG_RECEIVE)
			_qh_uid="$(json_get "$_qh_d" openid 2>/dev/null)" || _qh_uid=""
			log_info "qqbot: $_qh_t openid=$_qh_uid"
			dispatch "qqbot" "c2c_event" "$_qh_uid" "$_qh_t:$_qh_uid" "$_qh_d"
			;;
		MESSAGE_AUDIT_PASS|MESSAGE_AUDIT_REJECT)
			_qh_uid="$(json_get "$_qh_d" audit_id 2>/dev/null)" || _qh_uid=""
			dispatch "qqbot" "audit" "$_qh_uid" "$_qh_t:$_qh_uid" "$_qh_d"
			;;
		*)
			log_debug "qqbot: unhandled event $_qh_t"
			;;
	esac
	return 0
}

# ---- CGI entry ----------------------------------------------------------

# qqbot_webhook <body> [sig] [ts] → response JSON on stdout, _QQBOT_STATUS set
qqbot_webhook() {
	_qw_body="$1"
	_qw_sig="${2:-}"
	_qw_ts="${3:-}"
	_qqbot_set_status "200 OK"

	if [ -z "$_qw_body" ]; then
		_ERROR="qqbot: empty body"
		_qqbot_set_status "400 Bad Request"
		return 1
	fi

	_qw_op="$(json_get "$_qw_body" op 2>/dev/null)" || _qw_op=""
	case "$_qw_op" in
		13) qqbot_webhook_validate "$_qw_body" ;;
		0)  qqbot_webhook_event "$_qw_body" "$_qw_sig" "$_qw_ts" ;;
		*)
			log_debug "qqbot: ignoring op=${_qw_op:-none}"
			printf '{"op":12,"d":{}}'
			;;
	esac
}
