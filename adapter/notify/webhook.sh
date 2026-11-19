#!/bin/sh
# adapter/notify/webhook.sh — unified notification gateway (v2)
#
# POST /cgi-bin/router.sh/notify?token=<NOTIFY_WEBHOOK_TOKEN>
#
# Body (all fields optional unless noted):
# {
#   "to":       ["qqbot:group:<openid>", "qqbot:c2c:<openid>",
#                "telegram:chat:<id>", "discord:channel:<id>"],   # required
#   "text":     "正文",
#   "format":   "text" | "markdown",     # markdown → QQ msg_type=2
#   "card":     { ... },                 # QQ 图文卡片 msg_type=8（不能带按钮）
#   "media":    {"file":"/p/a.mp4","type":2} | {"url":"https://…","type":1}
#             | {"file_info":"…"},       # 富媒体 msg_type=7
#   "images":   ["/p/a.png", "token:<image_id>", "qqbot-media://image/v1/<token>"],
#   "at":       ["<group_member_openid>", ...],
#   "at_all":   true,
#   "reply_to": "<message_id>",          # 引用回复
#   "msg_id":   "<被动回复 msg_id>",      # 被动回复（5 分钟内，最多 5 次）
#   "event_id": "…",
#   "msg_seq":  1,
#   "recall":   "<message_id>" | [{"to":"qqbot:group:G1","message_id":"M"}],
#   "buttons":  [{"id":"retry","label":"重试","type":"callback|url|cmd",
#                 "style":0|1|3|4,"data":"a=1","url":"https://…",
#                 "visited_label":"…","enter":true,"reply":true,
#                 "group":"g1","row":0}],
#   "callback": "https://ci.example.com/hook"
# }
#
# Response:
#   {"ok":true,"sent":N,"failed":N,"results":[{"target":"…","ok":true,"message_id":"…"}]}
#   {"ok":false,"error":"…"} on request-level failure
#
# Targets use "platform:scene:id" — a plain colon-separated identifier, NOT a
# URL scheme. No custom :// protocol is defined or required.
#
# Button relay: when `callback` is present, every callback button's data gets a
# short key appended ("&_k=<hex>"). The key maps to the callback URL in
# var/state/notify-cb/<key>; the last key per chat is also recorded so that
# non-button interactions (feedback, clear-session, …) can be relayed too.
# Adapters hand the event to adapter/notify/relay.sh, which resolves the key and
# POSTs a uniform payload back to the original caller.
#
# Platform constraints baked in (all measured 2026-11-19):
#   * QQ renders keyboard / message_reference / @user only for msg_type=2, so a
#     text message carrying any of those is promoted to markdown automatically.
#   * QQ msg_type=8 (card) rejects keyboard with 40011021 → buttons dropped.
#   * QQ jump buttons accept https:// and appid: only; mqqapi:// is refused.
#   * QQ at-user needs group_member_openid and markdown; at-all needs admin.
#   * QQ pre-stored images must use qqbot-media://, never https.
#   * Telegram/Discord cannot upload a local file here — pass a URL/file_id.

. "$_HB/lib/core.sh"
. "$_HB/lib/log.sh"
. "$_HB/lib/auth.sh"
. "$_HB/lib/dispatch.sh"

_NOTIFY_CB_DIR="${_STATE_DIR:-$_HB/var/state}/notify-cb"
_NOTIFY_LAST_DIR="${_STATE_DIR:-$_HB/var/state}/notify-cb-last"
_NOTIFY_TMP="${_TMP_DIR:-$_HB/tmp}"
_NOTIFY_MAX_TARGETS="${NOTIFY_MAX_TARGETS:-10}"
_NOTIFY_CB_TTL_DAYS="${NOTIFY_CB_TTL_DAYS:-7}"
_NOTIFY_ALLOW_HOSTS="${NOTIFY_ALLOW_HOSTS:-}"
_NOTIFY_QQ_LABEL_MAX="${NOTIFY_QQ_LABEL_MAX:-10}"

# ---- request spec (shared by every per-platform sender) ----------------
_NR_TEXT="" _NR_FMT="" _NR_CARD="" _NR_MEDIA="" _NR_IMAGES="" _NR_AT=""
_NR_ATALL="" _NR_REPLY="" _NR_BTNS="" _NR_KEY="" _NR_MSGID="" _NR_EVENTID=""
_NR_SEQ="" _NR_RECALL=""
# last send result (message id), filled by the per-platform senders
_NR_MSG_OUT=""

# ---- small json helpers ------------------------------------------------

# _notify_jget <json> <key> → value, "" when absent/null
_notify_jget() {
	_njg_v="$(json_get "$1" "$2" 2>/dev/null)" || _njg_v=""
	case "$_njg_v" in NOTFOUND|null) _njg_v="" ;; esac
	printf '%s' "$_njg_v"
}

_notify_arr_len() {
	_nal_n="$(json_arr_len "$1" 2>/dev/null)" || _nal_n=0
	case "$_nal_n" in ''|*[!0-9]*) _nal_n=0 ;; esac
	printf '%s' "$_nal_n"
}

_notify_true() {
	case "$1" in 1|true|TRUE|yes|on) return 0 ;; esac
	return 1
}

# _notify_jjoin <a> <b> — append a JSON item to a comma list
_notify_jjoin() {
	if [ -z "$1" ]; then printf '%s' "$2"; else printf '%s,%s' "$1" "$2"; fi
}

# ---- callback URL guard (SSRF) -----------------------------------------
# The callback URL comes from the caller, so it must never reach loopback,
# link-local or RFC1918 space. Only http/https and a public host pass.
_notify_cb_ok() {
	case "$1" in
		http://*|https://*) : ;;
		*) return 1 ;;
	esac
	_nu="$1"
	_nu="${_nu#http://}"
	_nu="${_nu#https://}"
	_nhost="${_nu%%/*}"
	_nhost="${_nhost%%:*}"
	case "$_nhost" in
		''|localhost|*.localhost|127.*|0.*|10.*|192.168.*|169.254.*|'[::1]'|::1) return 1 ;;
	esac
	case "$_nhost" in
		172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 1 ;;
	esac
	# Literal-address checks cannot stop a public name that resolves to
	# 127.0.0.1 (or is re-pointed after the check: DNS rebinding). A host
	# allowlist is the only honest mitigation, so deployments that care set
	# NOTIFY_ALLOW_HOSTS="ci.example.com hooks.example.net" and nothing else
	# is called back.
	if [ -n "$_NOTIFY_ALLOW_HOSTS" ]; then
		case " $_NOTIFY_ALLOW_HOSTS " in
			*" $_nhost "*) : ;;
			*) return 1 ;;
		esac
	fi
	return 0
}

# _notify_cb_store <url> → short key on stdout, "" on failure
_notify_cb_store() {
	mkdir -p "$_NOTIFY_CB_DIR" 2>/dev/null || return 1
	_ncs_key="$(printf '%s' "$1$$$(date +%s)" | cksum | cut -d' ' -f1)"
	printf '%s' "$1" >"$_NOTIFY_CB_DIR/$_ncs_key" 2>/dev/null || return 1
	# keep the directory bounded, then drop anything past the TTL
	_ncs_n="$(ls "$_NOTIFY_CB_DIR" 2>/dev/null | wc -l | tr -d ' ')"
	case "$_ncs_n" in ''|*[!0-9]*) _ncs_n=0 ;; esac
	if [ "$_ncs_n" -gt 2000 ]; then
		ls -t "$_NOTIFY_CB_DIR" 2>/dev/null | tail -n +2001 >"$_NOTIFY_TMP/notify-prune.$$" 2>/dev/null
		while IFS= read -r _f; do
			[ -n "$_f" ] && rm -f "$_NOTIFY_CB_DIR/$_f" 2>/dev/null
		done <"$_NOTIFY_TMP/notify-prune.$$"
		rm -f "$_NOTIFY_TMP/notify-prune.$$"
	fi
	find "$_NOTIFY_CB_DIR" -maxdepth 1 -type f -mtime +"$_NOTIFY_CB_TTL_DAYS" \
		-exec rm -f {} \; 2>/dev/null
	printf '%s' "$_ncs_key"
}

# _notify_last_store <platform> <chat> <key>
# Remembers the newest callback key per chat so non-button interactions
# (message feedback, clear session, …) can still be relayed to the caller.
_notify_last_store() {
	[ -n "${3:-}" ] || return 0
	mkdir -p "$_NOTIFY_LAST_DIR" 2>/dev/null || return 0
	_nls_f="$(printf '%s-%s' "$1" "$2" | tr -c 'A-Za-z0-9_.-' '_')"
	printf '%s' "$3" >"$_NOTIFY_LAST_DIR/$_nls_f" 2>/dev/null
	return 0
}

# _notify_last_get <platform> <chat> → key, "" when none
_notify_last_get() {
	_nlg_f="$(printf '%s-%s' "$1" "$2" | tr -c 'A-Za-z0-9_.-' '_')"
	[ -f "$_NOTIFY_LAST_DIR/$_nlg_f" ] || return 0
	cat "$_NOTIFY_LAST_DIR/$_nlg_f" 2>/dev/null
}

# ---- button helpers ----------------------------------------------------

# _notify_btn_count <buttons_json> → element count, 0 when absent
_notify_btn_count() {
	case "$1" in ''|'[]'|NOTFOUND|null) printf '0'; return 0 ;; esac
	_nbc="$(_notify_arr_len "$1")"
	printf '%s' "$_nbc"
}

# _notify_btn_field <button_json> <field> → value, "" when absent
_notify_btn_field() {
	_nbf="$(json_get "$1" "$2" 2>/dev/null)" || _nbf=""
	case "$_nbf" in NOTFOUND|null) _nbf="" ;; esac
	printf '%s' "$_nbf"
}

# _notify_btn_data <raw data> <key> → data with the relay key appended
# A data string that already carries _k is left untouched (idempotent), so
# callers may pre-sign their own payloads.
_notify_btn_data() {
	case "$1" in
		*'_k='*) printf '%s' "$1" ;;
		*)
			if [ -n "${2:-}" ]; then printf '%s&_k=%s' "$1" "$2"
			else printf '%s' "$1"
			fi
			;;
	esac
}

# _notify_btn_kind <button_json> → callback|url|cmd
_notify_btn_kind() {
	_nbk_t="$(_notify_btn_field "$1" kind)"
	[ -n "$_nbk_t" ] || _nbk_t="$(_notify_btn_field "$1" type)"
	case "$_nbk_t" in
		url|link|jump|open|0)         printf 'url' ;;
		cmd|command|input|enter|text|2) printf 'cmd' ;;
		callback|cb|1)                printf 'callback' ;;
		'') case "$(_notify_btn_field "$1" url)" in
				?*) printf 'url' ;;
				*)  printf 'callback' ;;
			esac ;;
		*) printf 'callback' ;;
	esac
}

# _notify_btn_style <button_json> [default] → 0|1|3|4
_notify_btn_style() {
	_nbs_v="$(_notify_btn_field "$1" style)"
	case "$_nbs_v" in
		0|1|3|4) printf '%s' "$_nbs_v" ;;
		*) printf '%s' "${2:-1}" ;;
	esac
}

# _notify_btn_row <button_json> <default_row>
_notify_btn_row() {
	_nbr_r="$(_notify_btn_field "$1" row)"
	case "$_nbr_r" in ''|*[!0-9]*) _nbr_r="$2" ;; esac
	printf '%s' "$_nbr_r"
}

# _notify_max_row <buttons_json> → highest row index
_notify_max_row() {
	_nmr_n="$(_notify_btn_count "$1")"
	_nmr_i=0 _nmr_max=0
	while [ "$_nmr_i" -lt "$_nmr_n" ]; do
		_nmr_b="$(json_arr_at "$1" "$_nmr_i" 2>/dev/null)" || _nmr_b=""
		_nmr_r="$(_notify_btn_row "$_nmr_b" "$_nmr_i")"
		[ "$_nmr_r" -gt "$_nmr_max" ] 2>/dev/null && _nmr_max="$_nmr_r"
		_nmr_i=$((_nmr_i + 1))
	done
	printf '%s' "$_nmr_max"
}

# _notify_qq_btn <button_json> <key> → QQ button object
_notify_qq_btn() {
	_nqb_b="$1" _nqb_key="$2"
	_nqb_id="$(_notify_btn_field "$_nqb_b" id)"
	_nqb_lb="$(_notify_btn_field "$_nqb_b" label)"
	_nqb_vis="$(_notify_btn_field "$_nqb_b" visited_label)"
	_nqb_dt="$(_notify_btn_field "$_nqb_b" data)"
	_nqb_url="$(_notify_btn_field "$_nqb_b" url)"
	_nqb_grp="$(_notify_btn_field "$_nqb_b" group)"
	[ -n "$_nqb_id" ] || _nqb_id="btn$(_notify_btn_count "$_nqb_b")"
	[ -n "$_nqb_lb" ] || _nqb_lb="$_nqb_id"
	[ -n "$_nqb_vis" ] || _nqb_vis="$_nqb_lb"
	_nqb_style="$(_notify_btn_style "$_nqb_b" 1)"
	_nqb_kind="$(_notify_btn_kind "$_nqb_b")"

	# label >10 chars is rejected by the platform constructor (40034xxx);
	# warn but still send so the caller sees the real error.
	_nqb_len="$(printf '%s' "$_nqb_lb" | wc -m 2>/dev/null | tr -d ' ')"
	case "$_nqb_len" in ''|*[!0-9]*) _nqb_len=0 ;; esac
	if [ "$_nqb_len" -gt "$_NOTIFY_QQ_LABEL_MAX" ]; then
		log_warn "notify: qqbot button '$_nqb_id' label ${_nqb_len} chars (>${_NOTIFY_QQ_LABEL_MAX}) may be rejected"
	fi

	case "$_nqb_kind" in
		url)
			_nqb_ty=0
			_nqb_payload="$_nqb_url"
			case "$_nqb_payload" in
				'') log_warn "notify: qqbot url button '$_nqb_id' has no url"; _nqb_payload="$_nqb_dt" ;;
			esac
			# scheme links (mqqapi://) are refused in groups — no _k here,
			# a jump button never produces an interaction event.
			_nqb_act="$(json_obj type 0 data "$_nqb_payload" \
				permission "$(json_obj type 2)")"
			;;
		cmd)
			_nqb_ty=2
			_nqb_act="$(json_obj type 2 data "$(_notify_btn_data "$_nqb_dt" "$_nqb_key")" \
				permission "$(json_obj type 2)")"
			_notify_true "$(_notify_btn_field "$_nqb_b" enter)" && \
				_nqb_act="${_nqb_act%\}},\"enter\":true}"
			_notify_true "$(_notify_btn_field "$_nqb_b" reply)" && \
				_nqb_act="${_nqb_act%\}},\"reply\":true}"
			[ -n "$_nqb_grp" ] && _nqb_act="${_nqb_act%\}},\"group_id\":$(json_escape "$_nqb_grp")}"
			_nqb_act="$_nqb_act}"
			;;
		*)
			_nqb_ty=1
			_nqb_act="$(json_obj type 1 data "$(_notify_btn_data "$_nqb_dt" "$_nqb_key")" \
				permission "$(json_obj type 2)")"
			;;
	esac

	json_obj id "$_nqb_id" \
		render_data "$(json_obj label "$_nqb_lb" visited_label "$_nqb_vis" style "$_nqb_style")" \
		action "$_nqb_act"
}

# _notify_qq_rows <buttons> <key> → keyboard.content.rows
# One row per `row` value; without explicit rows every button gets its own row
# (QQ squeezes multi-button rows and long CJK labels are clipped first).
_notify_qq_rows() {
	_nqr_btns="$1" _nqr_key="$2"
	_nqr_n="$(_notify_btn_count "$_nqr_btns")"
	[ "$_nqr_n" -gt 0 ] || return 0
	_nqr_max="$(_notify_max_row "$_nqr_btns")"
	_nqr_out="" _nqr_r=0
	while [ "$_nqr_r" -le "$_nqr_max" ]; do
		_nqr_row="" _nqr_i=0
		while [ "$_nqr_i" -lt "$_nqr_n" ]; do
			_nqr_b="$(json_arr_at "$_nqr_btns" "$_nqr_i" 2>/dev/null)" || _nqr_b=""
			_nqr_rowidx="$(_notify_btn_row "$_nqr_b" "$_nqr_i")"
			_nqr_i=$((_nqr_i + 1))
			[ "$_nqr_rowidx" = "$_nqr_r" ] || continue
			_nqr_obj="$(_notify_qq_btn "$_nqr_b" "$_nqr_key")"
			_nqr_row="$(_notify_jjoin "$_nqr_row" "$_nqr_obj")"
		done
		[ -n "$_nqr_row" ] && _nqr_out="$(_notify_jjoin "$_nqr_out" "{\"buttons\":[$_nqr_row]}")"
		_nqr_r=$((_nqr_r + 1))
	done
	printf '[%s]' "$_nqr_out"
}

# ---- per-platform: QQ --------------------------------------------------

# _notify_qq_media <scene> <id> → file_info on stdout
_notify_qq_media() {
	_nqm_sc="$1" _nqm_id="$2"
	_nqm_fi="$(_notify_jget "$_NR_MEDIA" file_info)"
	[ -n "$_nqm_fi" ] && { printf '%s' "$_nqm_fi"; return 0; }
	_nqm_file="$(_notify_jget "$_NR_MEDIA" file)"
	_nqm_url="$(_notify_jget "$_NR_MEDIA" url)"
	_nqm_ty="$(_notify_jget "$_NR_MEDIA" type)"
	case "$_nqm_ty" in ''|*[!0-9]*) _nqm_ty=1 ;; esac

	if [ -n "$_nqm_file" ]; then
		[ -f "$_nqm_file" ] || { _ERROR="notify: media file not found: $_nqm_file"; return 1; }
		. "$_HB/adapter/qqbot/upload.sh"
		_nqm_r="$(qqbot_upload_any "$_nqm_sc" "$_nqm_id" "$_nqm_file" "$_nqm_ty" "${_nqm_file##*/}")" || return 1
	elif [ -n "$_nqm_url" ]; then
		if [ "$_nqm_sc" = "c2c" ]; then
			_nqm_r="$(qqbot_file_upload_c2c "$_nqm_id" "$_nqm_ty" "$_nqm_url" false)" || return 1
		else
			_nqm_r="$(qqbot_file_upload_group "$_nqm_id" "$_nqm_ty" "$_nqm_url" false)" || return 1
		fi
	else
		_ERROR="notify: media needs file, url or file_info"
		return 1
	fi

	_nqm_fi="$(_notify_jget "$_nqm_r" file_info)"
	[ -n "$_nqm_fi" ] || { _ERROR="notify: media upload returned no file_info"; return 1; }
	printf '%s' "$_nqm_fi"
}

# _notify_qq_md_body [allow_tags] → body with @-tags and pre-stored images
# allow_tags=0 (msg_type 0/7/8) skips at-user tags and image refs: both are
# markdown-only constructs and would otherwise leak as literal text.
_notify_qq_md_body() {
	_nqb_md="$_NR_TEXT"
	_nqb_tags="${1:-1}"

	# at-user tags only render in markdown
	if [ "$_nqb_tags" = "1" ] && [ -n "$_NR_AT" ]; then
		_nqb_n="$(_notify_arr_len "$_NR_AT")" _nqb_i=0 _nqb_at=""
		while [ "$_nqb_i" -lt "$_nqb_n" ]; do
			_nqb_oid="$(json_arr_at "$_NR_AT" "$_nqb_i" 2>/dev/null)" || _nqb_oid=""
			_nqb_i=$((_nqb_i + 1))
			case "$_nqb_oid" in ''|NOTFOUND|null) continue ;; esac
			_nqb_at="$_nqb_at$(qqbot_tag_at "$_nqb_oid")"
		done
		[ -n "$_nqb_at" ] && _nqb_md="$_nqb_at$_nqb_md"
	fi

	# images: upload to the media library, then reference qqbot-media://
	if [ "$_nqb_tags" = "1" ] && [ -n "$_NR_IMAGES" ]; then
		_nqb_n="$(_notify_arr_len "$_NR_IMAGES")" _nqb_i=0
		while [ "$_nqb_i" -lt "$_nqb_n" ]; do
			_nqb_img="$(json_arr_at "$_NR_IMAGES" "$_nqb_i" 2>/dev/null)" || _nqb_img=""
			_nqb_i=$((_nqb_i + 1))
			case "$_nqb_img" in ''|NOTFOUND|null) continue ;; esac
			case "$_nqb_img" in
				token:*)          _nqb_u="qqbot-media://image/v1/${_nqb_img#token:}" ;;
				qqbot-media://*)  _nqb_u="$_nqb_img" ;;
				*)
					if [ -f "$_nqb_img" ]; then
						if qqbot_media_image_upload "$_nqb_img" >/dev/null 2>&1; then
							_nqb_u="$_QQBOT_IMAGE_URL"
						else
							log_warn "notify: image upload failed ($_nqb_img): $_ERROR"
							_nqb_u=""
						fi
					else
						log_warn "notify: image not found: $_nqb_img"
						_nqb_u=""
					fi
					;;
			esac
			[ -n "$_nqb_u" ] || continue
			_nqb_md="$_nqb_md
$(qqbot_md_image "$_nqb_u" "img" "${QQBOT_MD_IMAGE_W:-}" "${QQBOT_MD_IMAGE_H:-}")"
		done
	fi
	printf '%s' "$_nqb_md"
}

# notify_send_qqbot <scene> <openid>
notify_send_qqbot() {
	_nq_sc="$1" _nq_id="$2"
	case "$_nq_sc" in c2c) _nq_scene="c2c" ;; *) _nq_scene="group" ;; esac

	_nq_btn_n="$(_notify_btn_count "$_NR_BTNS")"

	# msg_type precedence: card(8) > media(7) > markdown(2) > text(0).
	# Keyboard, message_reference and at-user only render as markdown.
	_nq_ty=0
	if [ -n "$_NR_CARD" ]; then
		_nq_ty=8
	elif [ -n "$_NR_MEDIA" ]; then
		_nq_ty=7
	elif [ "$_NR_FMT" = "markdown" ] || [ -n "$_NR_IMAGES" ] || [ -n "$_NR_AT" ] \
		|| [ -n "$_NR_REPLY" ] || [ "$_nq_btn_n" -gt 0 ]; then
		_nq_ty=2
	fi

	if [ "$_nq_ty" = "2" ]; then
		_nq_body="$(_notify_qq_md_body 1)"
		[ "$_NR_ATALL" = "1" ] && _nq_body="$(qqbot_tag_at_everyone)$_nq_body"
	else
		_nq_body="$(_notify_qq_md_body 0)"
	fi

	_nq_kb=""
	if [ "$_nq_btn_n" -gt 0 ]; then
		if [ "$_nq_ty" = "8" ]; then
			log_warn "notify: qqbot card(msg_type=8) cannot carry keyboard (40011021), buttons dropped"
		else
			_nq_kb="$(_notify_qq_rows "$_NR_BTNS" "$_NR_KEY")"
		fi
	fi

	_nq_fi=""
	if [ "$_nq_ty" = "7" ]; then
		_nq_fi="$(_notify_qq_media "$_nq_scene" "$_nq_id")" || return 1
	fi

	set -- --track
	case "$_nq_ty" in
		8) set -- "$@" --card "$_NR_CARD" ;;
		7) set -- "$@" --media "$_nq_fi" ;;
		2) set -- "$@" --md ;;
	esac
	set -- "$@" --text "$_nq_body"
	[ -n "$_nq_kb" ] && set -- "$@" --keyboard-rows "$_nq_kb"
	[ -n "$_NR_REPLY" ] && set -- "$@" --reply "$_NR_REPLY"
	[ -n "$_NR_MSGID" ] && set -- "$@" --msg-id "$_NR_MSGID"
	[ -n "$_NR_EVENTID" ] && set -- "$@" --event-id "$_NR_EVENTID"
	[ -n "$_NR_SEQ" ] && set -- "$@" --msg-seq "$_NR_SEQ"

	_nq_r="$(qqbot_msg_send "$_nq_scene" "$_nq_id" "$@")" || {
		_ERROR="qqbot.send $_nq_scene: ${_ERROR:-failed}"
		return 1
	}
	_NR_MSG_OUT="$(_notify_jget "$_nq_r" id)"
	_notify_last_store qqbot "$_nq_id" "$_NR_KEY"
	# NB: raw platform responses must never reach stdout — router.sh has already
	# emitted the CGI header and everything printed here becomes the HTTP body.
}

# ---- per-platform: Telegram --------------------------------------------

# _notify_tg_kb <buttons> <key> → inline_keyboard rows or ""
_notify_tg_kb() {
	_ntk_btns="$1" _ntk_key="$2"
	_ntk_n="$(_notify_btn_count "$_ntk_btns")"
	[ "$_ntk_n" -gt 0 ] || return 0
	_ntk_max="$(_notify_max_row "$_ntk_btns")"
	_ntk_out="" _ntk_r=0
	while [ "$_ntk_r" -le "$_ntk_max" ]; do
		_ntk_row="" _ntk_i=0
		while [ "$_ntk_i" -lt "$_ntk_n" ]; do
			_ntk_b="$(json_arr_at "$_ntk_btns" "$_ntk_i" 2>/dev/null)" || _ntk_b=""
			_ntk_rowidx="$(_notify_btn_row "$_ntk_b" "$_ntk_i")"
			_ntk_i=$((_ntk_i + 1))
			[ "$_ntk_rowidx" = "$_ntk_r" ] || continue
			_ntk_id="$(_notify_btn_field "$_ntk_b" id)"
			_ntk_lb="$(_notify_btn_field "$_ntk_b" label)"
			_ntk_dt="$(_notify_btn_field "$_ntk_b" data)"
			_ntk_url="$(_notify_btn_field "$_ntk_b" url)"
			[ -n "$_ntk_id" ] || _ntk_id="btn$_ntk_i"
			[ -n "$_ntk_lb" ] || _ntk_lb="$_ntk_id"
			case "$(_notify_btn_kind "$_ntk_b")" in
				url) _ntk_obj="$(json_obj text "$_ntk_lb" url "$_ntk_url")" ;;
				*)   _ntk_obj="$(json_obj text "$_ntk_lb" \
						callback_data "$_ntk_id|$(_notify_btn_data "$_ntk_dt" "$_ntk_key")")" ;;
			esac
			_ntk_row="$(_notify_jjoin "$_ntk_row" "$_ntk_obj")"
		done
		[ -n "$_ntk_row" ] && _ntk_out="$(_notify_jjoin "$_ntk_out" "[$_ntk_row]")"
		_ntk_r=$((_ntk_r + 1))
	done
	printf '[%s]' "$_ntk_out"
}

# _notify_tg_media_url → media URL/file_id for sendPhoto|Video|Document
# Telegram fetches by itself, so a local path is unusable here.
_notify_tg_media_url() {
	_ntm_u=""
	if [ -n "$_NR_MEDIA" ]; then
		_ntm_u="$(_notify_jget "$_NR_MEDIA" url)"
		[ -n "$_ntm_u" ] || _ntm_u="$(_notify_jget "$_NR_MEDIA" file_id)"
	fi
	if [ -z "$_ntm_u" ] && [ -n "$_NR_IMAGES" ] && [ "$(_notify_arr_len "$_NR_IMAGES")" -gt 0 ]; then
		_ntm_u="$(json_arr_at "$_NR_IMAGES" 0 2>/dev/null)" || _ntm_u=""
	fi
	case "$_ntm_u" in
		/*|[!/]*) case "$_ntm_u" in
			''|http://*|https://*) : ;;
			*) printf ''; return 0 ;;
		esac ;;
	esac
	printf '%s' "$_ntm_u"
}

# notify_send_telegram <chat_id>
notify_send_telegram() {
	_nt_cid="$1"
	_nt_txt="$_NR_TEXT"
	_nt_kb="$(_notify_tg_kb "$_NR_BTNS" "$_NR_KEY")"
	_nt_mode=""
	[ "$_NR_FMT" = "markdown" ] && _nt_mode="Markdown"
	_nt_reply=""
	case "$_NR_REPLY" in
		''|*[!0-9]*) : ;;
		*) _nt_reply="$(json_obj message_id "$_NR_REPLY")" ;;
	esac

	_nt_media="$(_notify_tg_media_url)"
	_nt_method="sendMessage" _nt_key="text"
	[ -n "$_nt_media" ] && { _nt_method="sendPhoto"; _nt_key="photo"; }
	# local file / token-only media cannot be pushed by Telegram directly
	if [ -z "$_nt_media" ] && [ -n "$_NR_MEDIA" ]; then
		log_warn "notify: telegram needs a url/file_id for media, local files are skipped"
	fi

	_nt_body="$(json_obj chat_id "$_nt_cid" "$_nt_key" "$_nt_txt")"
	[ -n "$_nt_media" ] && _nt_body="$(json_obj chat_id "$_nt_cid" "$_nt_key" "$_nt_media" caption "$_nt_txt")"
	[ -n "$_nt_mode" ] && _nt_body="${_nt_body%\}},\"parse_mode\":$(json_escape "$_nt_mode")}"
	[ -n "$_nt_reply" ] && _nt_body="${_nt_body%\}},\"reply_parameters\":$_nt_reply}"
	[ -n "$_nt_kb" ] && _nt_body="${_nt_body%\}},\"reply_markup\":$(json_obj inline_keyboard "$_nt_kb")}"
	_nt_body="$_nt_body}"

	_nt_r="$(_tg_api "$_nt_method" "$_nt_body" "tg.notify")" || {
		# Markdown V1 is picky: retry once as plain text so a stray _ or *
		# never swallows the whole notification.
		if [ -n "$_nt_mode" ]; then
			log_warn "notify: telegram markdown rejected, retrying as plain text"
			_nt_body="$(json_obj chat_id "$_nt_cid" "$_nt_key" "$_nt_txt")"
			[ -n "$_nt_media" ] && _nt_body="$(json_obj chat_id "$_nt_cid" "$_nt_key" "$_nt_media" caption "$_nt_txt")"
			[ -n "$_nt_reply" ] && _nt_body="${_nt_body%\}},\"reply_parameters\":$_nt_reply}"
			[ -n "$_nt_kb" ] && _nt_body="${_nt_body%\}},\"reply_markup\":$(json_obj inline_keyboard "$_nt_kb")}"
			_nt_body="$_nt_body}"
			_nt_r="$(_tg_api "$_nt_method" "$_nt_body" "tg.notify.retry")" || {
				_ERROR="tg.send: ${_ERROR:-failed}"; return 1
			}
		else
			_ERROR="tg.send: ${_ERROR:-failed}"; return 1
		fi
	}

	# remaining images go out as separate photos
	if [ -n "$_NR_IMAGES" ]; then
		_nt_n="$(_notify_arr_len "$_NR_IMAGES")" _nt_i=1
		while [ "$_nt_i" -lt "$_nt_n" ]; do
			_nt_img="$(json_arr_at "$_NR_IMAGES" "$_nt_i" 2>/dev/null)" || _nt_img=""
			_nt_i=$((_nt_i + 1))
			case "$_nt_img" in
				''|NOTFOUND|null|token:*|qqbot-media://*) continue ;;
				http://*|https://*) _tg_api "sendPhoto" \
					"$(json_obj chat_id "$_nt_cid" photo "$_nt_img")" "tg.notify.photo" >/dev/null 2>&1 ;;
			esac
		done
	fi

	_NR_MSG_OUT="$(_notify_jget "$(json_get "$_nt_r" result 2>/dev/null)" message_id)"
	_notify_last_store telegram "$_nt_cid" "$_NR_KEY"
	printf '%s' "$_nt_r"
}

# ---- per-platform: Discord ---------------------------------------------

# _notify_dc_style <button_json> <kind> → Discord button style
_notify_dc_style() {
	_nds_kind="$2"
	[ "$_nds_kind" = "url" ] && { printf '5'; return 0; }
	case "$(_notify_btn_style "$1" 1)" in
		0) printf '2' ;;
		1) printf '1' ;;
		3) printf '3' ;;
		4) printf '4' ;;
		*) printf '1' ;;
	esac
}

# _notify_dc_components <buttons> <key> → components array or ""
# Discord allows at most 5 rows of 5 buttons; anything past that is dropped.
_notify_dc_components() {
	_ndc_btns="$1" _ndc_key="$2"
	_ndc_n="$(_notify_btn_count "$_ndc_btns")"
	[ "$_ndc_n" -gt 0 ] || return 0
	_ndc_max="$(_notify_max_row "$_ndc_btns")"
	_ndc_out="" _ndc_r=0 _ndc_rows=0
	while [ "$_ndc_r" -le "$_ndc_max" ] && [ "$_ndc_rows" -lt 5 ]; do
		_ndc_row="" _ndc_i=0 _ndc_c=0
		while [ "$_ndc_i" -lt "$_ndc_n" ] && [ "$_ndc_c" -lt 5 ]; do
			_ndc_b="$(json_arr_at "$_ndc_btns" "$_ndc_i" 2>/dev/null)" || _ndc_b=""
			_ndc_rowidx="$(_notify_btn_row "$_ndc_b" "$_ndc_i")"
			_ndc_i=$((_ndc_i + 1))
			[ "$_ndc_rowidx" = "$_ndc_r" ] || continue
			_ndc_id="$(_notify_btn_field "$_ndc_b" id)"
			_ndc_lb="$(_notify_btn_field "$_ndc_b" label)"
			_ndc_dt="$(_notify_btn_field "$_ndc_b" data)"
			_ndc_url="$(_notify_btn_field "$_ndc_b" url)"
			[ -n "$_ndc_id" ] || _ndc_id="btn$_ndc_i"
			[ -n "$_ndc_lb" ] || _ndc_lb="$_ndc_id"
			_ndc_kind="$(_notify_btn_kind "$_ndc_b")"
			_ndc_style="$(_notify_dc_style "$_ndc_b" "$_ndc_kind")"
			if [ "$_ndc_kind" = "url" ]; then
				_ndc_obj="$(json_obj type 2 style "$_ndc_style" label "$_ndc_lb" url "$_ndc_url")"
			else
				_ndc_obj="$(json_obj type 2 style "$_ndc_style" label "$_ndc_lb" \
					custom_id "$_ndc_id|$(_notify_btn_data "$_ndc_dt" "$_ndc_key")")"
			fi
			_ndc_row="$(_notify_jjoin "$_ndc_row" "$_ndc_obj")"
			_ndc_c=$((_ndc_c + 1))
		done
		[ -n "$_ndc_row" ] && {
			_ndc_out="$(_notify_jjoin "$_ndc_out" "{\"type\":1,\"components\":[$_ndc_row]}")"
			_ndc_rows=$((_ndc_rows + 1))
		}
		_ndc_r=$((_ndc_r + 1))
	done
	[ "$_ndc_r" -le "$_ndc_max" ] && log_warn "notify: discord component limit reached, extra buttons dropped"
	[ -n "$_ndc_out" ] && printf '[%s]' "$_ndc_out"
}

# notify_send_discord <channel_id>
notify_send_discord() {
	_nd_cid="$1"
	_nd_body_parts="content:$_NR_TEXT"
	_nd_comp="$(_notify_dc_components "$_NR_BTNS" "$_NR_KEY")"

	_nd_body="$(json_obj content "$_NR_TEXT")"
	[ -n "$_nd_comp" ] && _nd_body="${_nd_body%\}},\"components\":$_nd_comp}"
	[ -n "$_NR_REPLY" ] && _nd_body="${_nd_body%\}},\"message_reference\":$(json_obj message_id "$_NR_REPLY")}"

	# a local file cannot be attached through this JSON path; a public image
	# URL can ride along as an embed.
	_nd_img=""
	if [ -n "$_NR_MEDIA" ]; then
		_nd_img="$(_notify_jget "$_NR_MEDIA" url)"
		[ -n "$_nd_img" ] || log_warn "notify: discord needs a url for media, local files are skipped"
	fi
	if [ -z "$_nd_img" ] && [ -n "$_NR_IMAGES" ] && [ "$(_notify_arr_len "$_NR_IMAGES")" -gt 0 ]; then
		_nd_img="$(json_arr_at "$_NR_IMAGES" 0 2>/dev/null)" || _nd_img=""
		case "$_nd_img" in http://*|https://*) : ;; *) _nd_img="" ;; esac
	fi
	[ -n "$_nd_img" ] && _nd_body="${_nd_body%\}},\"embeds\":[{\"image\":{\"url\":$(json_escape "$_nd_img")}}]}"
	_nd_body="$_nd_body}"

	_nd_r="$(_dc_api POST "/channels/$_nd_cid/messages" "$_nd_body")" || {
		_ERROR="dc.send: ${_ERROR:-failed}"; return 1
	}
	_NR_MSG_OUT="$(_notify_jget "$_nd_r" id)"
	_notify_last_store discord "$_nd_cid" "$_NR_KEY"
	printf '%s' "$_nd_r"
}

# ---- recall ------------------------------------------------------------

# notify_recall_one <target> <message_id>
notify_recall_one() {
	_nro_s="$(_notify_split "$1")" || { _ERROR="notify: bad target '$1'"; return 1; }
	_nro_pf="${_nro_s%%	*}"
	_nro_rest="${_nro_s#*	}"
	_nro_sc="${_nro_rest%%	*}"
	_nro_id="${_nro_rest#*	}"
	case "$_nro_pf" in
		qqbot)
			. "$_HB/adapter/qqbot/core.sh"
			. "$_HB/adapter/qqbot/message.sh"
			case "$_nro_sc" in
				c2c) qqbot_message_recall_c2c "$_nro_id" "$2" 2>/dev/null || \
					qqbot_message_recall_group "$_nro_id" "$2" ;;
				*)   qqbot_message_recall_group "$_nro_id" "$2" ;;
			esac
			;;
		telegram)
			. "$_HB/adapter/telegram/core.sh"
			. "$_HB/adapter/telegram/message.sh"
			tg_deleteMessage "$_nro_id" "$2" >/dev/null 2>&1
			;;
		discord)
			. "$_HB/adapter/discord/core.sh"
			_dc_api DELETE "/channels/$_nro_id/messages/$2" "" >/dev/null 2>&1
			;;
		*)
			_ERROR="notify: bad target '$1'"; return 1 ;;
	esac
}

# ---- target dispatch ---------------------------------------------------

# _notify_split <target> → "platform\tscene\tid", 1 on a malformed target
_notify_split() {
	case "$1" in
		*:*:*)
			_ns_pf="${1%%:*}"
			_ns_rest="${1#*:}"
			_ns_sc="${_ns_rest%%:*}"
			_ns_id="${_ns_rest#*:}"
			;;
		*:*)
			_ns_pf="${1%%:*}"
			_ns_id="${1#*:}"
			case "$_ns_pf" in
				qqbot)    _ns_sc="group" ;;
				discord)  _ns_sc="channel" ;;
				*)        _ns_sc="chat" ;;
			esac
			;;
		*) return 1 ;;
	esac
	case "$_ns_pf" in qqbot|telegram|discord) : ;; *) return 1 ;; esac
	case "$_ns_id" in ''|*[!0-9A-Za-z_@.-]*) return 1 ;; esac
	printf '%s\t%s\t%s' "$_ns_pf" "$_ns_sc" "$_ns_id"
}

# notify_dispatch_one <target>
notify_dispatch_one() {
	_ndo_s="$(_notify_split "$1")" || {
		log_warn "notify: bad target '$1'"
		return 1
	}
	_ndo_pf="${_ndo_s%%	*}"
	_ndo_rest="${_ndo_s#*	}"
	_ndo_sc="${_ndo_rest%%	*}"
	_ndo_id="${_ndo_rest#*	}"
	_NR_MSG_OUT=""
	case "$_ndo_pf" in
		qqbot)
			. "$_HB/adapter/qqbot/core.sh"
			. "$_HB/adapter/qqbot/message.sh"
			. "$_HB/adapter/qqbot/richtext.sh"
			notify_send_qqbot "$_ndo_sc" "$_ndo_id" >/dev/null
			;;
		telegram)
			. "$_HB/adapter/telegram/core.sh"
			. "$_HB/adapter/telegram/message.sh"
			notify_send_telegram "$_ndo_id" >/dev/null
			;;
		discord)
			. "$_HB/adapter/discord/core.sh"
			notify_send_discord "$_ndo_id" >/dev/null
			;;
	esac
}

# ---- entry -------------------------------------------------------------

# notify_webhook <raw json body> → response body on stdout, _ERROR on failure
notify_webhook() {
	_nw_body="$1"
	if [ -z "$_nw_body" ]; then
		_ERROR="notify: empty body"
		printf '{"ok":false,"error":"empty body"}'
		return 1
	fi

	_NR_TEXT="$(_notify_jget "$_nw_body" text)"
	_NR_FMT="$(_notify_jget "$_nw_body" format)"
	case "$_NR_FMT" in markdown|md) _NR_FMT="markdown" ;; *) _NR_FMT="text" ;; esac
	_NR_CARD="$(_notify_jget "$_nw_body" card)"
	_NR_MEDIA="$(_notify_jget "$_nw_body" media)"
	_NR_IMAGES="$(_notify_jget "$_nw_body" images)"
	_NR_AT="$(_notify_jget "$_nw_body" at)"
	_NR_ATALL=0; _notify_true "$(_notify_jget "$_nw_body" at_all)" && _NR_ATALL=1
	_NR_REPLY="$(_notify_jget "$_nw_body" reply_to)"
	_NR_MSGID="$(_notify_jget "$_nw_body" msg_id)"
	_NR_EVENTID="$(_notify_jget "$_nw_body" event_id)"
	_NR_SEQ="$(_notify_jget "$_nw_body" msg_seq)"
	_NR_RECALL="$(_notify_jget "$_nw_body" recall)"
	_NR_BTNS="$(_notify_jget "$_nw_body" buttons)"
	_nw_cb="$(_notify_jget "$_nw_body" callback)"

	_nw_to="$(_notify_jget "$_nw_body" to)"
	case "$_nw_to" in ''|[Nn]ull) _nw_to="[]" ;; esac

	# recall-only requests carry no text
	if [ -z "$_NR_TEXT" ] && [ -z "$_NR_RECALL" ] && [ -z "$_NR_MEDIA" ] && [ -z "$_NR_CARD" ]; then
		_ERROR="notify: missing text"
		printf '{"ok":false,"error":"missing text"}'
		return 1
	fi

	_NR_KEY=""
	if [ -n "$_nw_cb" ]; then
		if ! _notify_cb_ok "$_nw_cb"; then
			_ERROR="notify: callback url rejected (SSRF guard)"
			printf '{"ok":false,"error":"callback url rejected"}'
			return 1
		fi
		_NR_KEY="$(_notify_cb_store "$_nw_cb")"
		[ -n "$_NR_KEY" ] || log_warn "notify: callback key store failed"
	fi

	_nw_ok=0 _nw_fail=0
	_nw_res=""
	# tmp/ is not tracked by git, so a fresh checkout may lack it.
	[ -d "$_NOTIFY_TMP" ] || mkdir -p "$_NOTIFY_TMP" 2>/dev/null
	_nw_resf="$_NOTIFY_TMP/notify-res.$$"
	: >"$_nw_resf"

	# ---- recall mode ----
	if [ -n "$_NR_RECALL" ]; then
		_nw_rty="$(json_type "$_nw_body" recall 2>/dev/null)" || _nw_rty=""
		if [ "$_nw_rty" = "array" ]; then
			_nw_n="$(_notify_arr_len "$_NR_RECALL")" _nw_i=0
			while [ "$_nw_i" -lt "$_nw_n" ] && [ "$_nw_i" -lt "$_NOTIFY_MAX_TARGETS" ]; do
				_nw_item="$(json_arr_at "$_NR_RECALL" "$_nw_i" 2>/dev/null)" || _nw_item=""
				_nw_i=$((_nw_i + 1))
				_nw_t="$(_notify_jget "$_nw_item" to)"
				_nw_mid="$(_notify_jget "$_nw_item" message_id)"
				case "$_nw_t" in ''|NOTFOUND|null) _nw_t="$(_notify_jget "$_nw_item" target)" ;; esac
				if [ -z "$_nw_mid" ]; then
					_nw_fail=$((_nw_fail + 1))
					printf '{"target":%s,"ok":false,"error":"missing message_id"}\n' \
						"$(json_escape "$_nw_t")" >>"$_nw_resf"
					continue
				fi
				if notify_recall_one "$_nw_t" "$_nw_mid"; then
					_nw_ok=$((_nw_ok + 1))
					printf '{"target":%s,"ok":true,"message_id":%s}\n' \
						"$(json_escape "$_nw_t")" "$(json_escape "$_nw_mid")" >>"$_nw_resf"
				else
					_nw_fail=$((_nw_fail + 1))
					log_err "notify: recall failed target=$_nw_t mid=$_nw_mid: $_ERROR"
					printf '{"target":%s,"ok":false,"error":%s}\n' \
						"$(json_escape "$_nw_t")" "$(json_escape "${_ERROR:-recall failed}")" >>"$_nw_resf"
				fi
			done
		else
			_nw_n="$(_notify_arr_len "$_nw_to")" _nw_i=0
			while [ "$_nw_i" -lt "$_nw_n" ] && [ "$_nw_i" -lt "$_NOTIFY_MAX_TARGETS" ]; do
				_nw_t="$(json_arr_at "$_nw_to" "$_nw_i" 2>/dev/null)" || _nw_t=""
				_nw_i=$((_nw_i + 1))
				case "$_nw_t" in ''|NOTFOUND|null) continue ;; esac
				if notify_recall_one "$_nw_t" "$_NR_RECALL"; then
					_nw_ok=$((_nw_ok + 1))
					printf '{"target":%s,"ok":true,"message_id":%s}\n' \
						"$(json_escape "$_nw_t")" "$(json_escape "$_NR_RECALL")" >>"$_nw_resf"
				else
					_nw_fail=$((_nw_fail + 1))
					log_err "notify: recall failed target=$_nw_t: $_ERROR"
					printf '{"target":%s,"ok":false,"error":%s}\n' \
						"$(json_escape "$_nw_t")" "$(json_escape "${_ERROR:-recall failed}")" >>"$_nw_resf"
				fi
			done
		fi
	else
		# ---- send mode ----
		_nw_n="$(_notify_arr_len "$_nw_to")" _nw_i=0
		while [ "$_nw_i" -lt "$_nw_n" ] && [ "$_nw_i" -lt "$_NOTIFY_MAX_TARGETS" ]; do
			_nw_t="$(json_arr_at "$_nw_to" "$_nw_i" 2>/dev/null)" || _nw_t=""
			_nw_i=$((_nw_i + 1))
			case "$_nw_t" in ''|NOTFOUND|null) continue ;; esac
			_NR_MSG_OUT=""
			if notify_dispatch_one "$_nw_t"; then
				_nw_ok=$((_nw_ok + 1))
				printf '{"target":%s,"ok":true,"message_id":%s}\n' \
					"$(json_escape "$_nw_t")" "$(json_escape "$_NR_MSG_OUT")" >>"$_nw_resf"
			else
				_nw_fail=$((_nw_fail + 1))
				log_err "notify: send failed target=$_nw_t: $_ERROR"
				printf '{"target":%s,"ok":false,"error":%s}\n' \
					"$(json_escape "$_nw_t")" "$(json_escape "${_ERROR:-send failed}")" >>"$_nw_resf"
			fi
		done
	fi

	while IFS= read -r _nw_line; do
		[ -n "$_nw_line" ] && _nw_res="$(_notify_jjoin "$_nw_res" "$_nw_line")"
	done <"$_nw_resf"
	rm -f "$_nw_resf"

	log_info "notify: sent ok=$_nw_ok fail=$_nw_fail key=${_NR_KEY:-none}"
	printf '{"ok":true,"sent":%d,"failed":%d,"results":[%s]}' \
		"$_nw_ok" "$_nw_fail" "$_nw_res"
	return 0
}
