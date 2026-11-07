# plugin/sync/handler.sh — cross-platform sync router
# Called by dispatch: sync_handler <pf> <evt> <uid> <txt> <raw>

[ -z "${_HB:-}" ] && _HB="$(pwd)"

# Source all sub-modules
. "$_HB/plugin/sync/common.sh"
. "$_HB/plugin/sync/from_qq.sh"
. "$_HB/plugin/sync/from_tg.sh"
. "$_HB/plugin/sync/from_dc.sh"
. "$_HB/plugin/sync/from_qqbot.sh"

sync_handler() {
	_pf="$1" _evt="$2" _uid="$3" _txt="$4" _raw="$5"

	# TG reaction → QQ/DC: lookup mappings and apply reaction
	if [ "$_evt" = "reaction" ] && [ "$_pf" = "telegram" ]; then
		_tcid="$3" _tmid="$4" _rdata="$5"

		# URL segments are attacker-controlled; both are used as path
		# components of var/state/msg-map{,-rev} below.
		_sync_safe_id "$_tcid" && _sync_safe_id "$_tmid" \
			|| { log_warn "sync: reaction unsafe id tcid=$_tcid tmid=$_tmid"; return 0; }

		# --- new_reaction (add) ---
		_new="$(json_get "$_rdata" new_reaction 2>/dev/null)" || _new=""
		if [ -n "$_new" ] && [ "$_new" != "NOTFOUND" ]; then
			_emojis="$(printf '%s' "$_new" | grep -o '"emoji":"[^"]*"' | sed 's/"emoji":"//g;s/"//g')"

			# TG → QQ
			_map="$_STATE_DIR/msg-map/$_tcid/$_tmid"
			if [ -f "$_map" ]; then
				read -r _gid _rseq < "$_map"
				for _emoji in $_emojis; do
					_code="$(_reaction_code "$_emoji")"
					qq_group_send_reaction "$_gid" "$_rseq" "$_code" true
					log_info "sync: tg_reaction->qq $_emoji(${_code}) gid=$_gid seq=$_rseq"
				done
			else
				log_debug "sync: reaction no qq-map $_tcid/$_tmid"
			fi

			# TG → DC
			_rev_map="$_STATE_DIR/msg-map-rev/$_tcid/$_tmid"
			if [ -f "$_rev_map" ]; then
				while read -r _tpf _dc_cid _dc_mid; do
					if [ "$_tpf" = "discord" ] && [ -n "$_dc_mid" ]; then
						for _emoji in $_emojis; do
							_enc="$(_emoji_url_encode "$_emoji")"
							dc_reaction_add "$_dc_cid" "$_dc_mid" "$_enc" >/dev/null 2>/dev/null \
								&& log_info "sync: tg_reaction->dc $_emoji(${_enc}) cid=$_dc_cid mid=$_dc_mid" \
								|| log_err "sync: tg_reaction->dc FAIL: $_ERROR"
						done
					fi
				done < "$_rev_map"
			fi
		fi

		# --- old_reaction (remove) ---
		_old="$(json_get "$_rdata" old_reaction 2>/dev/null)" || _old=""
		if [ -n "$_old" ] && [ "$_old" != "NOTFOUND" ]; then
			_old_emojis="$(printf '%s' "$_old" | grep -o '"emoji":"[^"]*"' | sed 's/"emoji":"//g;s/"//g')"

			# TG → QQ remove
			_map="$_STATE_DIR/msg-map/$_tcid/$_tmid"
			if [ -f "$_map" ]; then
				read -r _gid _rseq < "$_map"
				for _emoji in $_old_emojis; do
					_code="$(_reaction_code "$_emoji")"
					qq_group_send_reaction "$_gid" "$_rseq" "$_code" false
					log_info "sync: tg_reaction_rm->qq $_emoji(${_code}) gid=$_gid seq=$_rseq"
				done
			fi

			# TG → DC remove
			_rev_map="$_STATE_DIR/msg-map-rev/$_tcid/$_tmid"
			if [ -f "$_rev_map" ]; then
				while read -r _tpf _dc_cid _dc_mid; do
					if [ "$_tpf" = "discord" ] && [ -n "$_dc_mid" ]; then
						for _emoji in $_old_emojis; do
							_enc="$(_emoji_url_encode "$_emoji")"
							dc_reaction_delete "$_dc_cid" "$_dc_mid" "$_enc" >/dev/null 2>/dev/null \
								&& log_info "sync: tg_reaction_rm->dc $_emoji(${_enc}) cid=$_dc_cid mid=$_dc_mid" \
								|| log_err "sync: tg_reaction_rm->dc FAIL: $_ERROR"
						done
					fi
				done < "$_rev_map"
			fi
		fi
		return 0
	fi

	# Loop prevention 1: emoji prefix = already forwarded
	case "$_txt" in "🐧"*|"✈️"*|"👾"*|"🅠"*) return 0 ;; esac

	# QQ message_recall to TG/DC deleteMessage
	if [ "$_evt" = "message_recall" ] && [ "$_pf" = "qq" ]; then
		_gid="$(json_get "$_raw" peer_id 2>/dev/null)" || _gid=""
		_seq="$(json_get "$_raw" message_seq 2>/dev/null)" || _seq=""
		if [ -n "$_gid" ] && [ -n "$_seq" ] && [ "$_gid" != "NOTFOUND" ] && [ "$_seq" != "NOTFOUND" ]; then
			# Both come from the payload and are later used as path
			# components (msg-map lookups, and rm -f further down).
			_sync_safe_id "$_gid" && _sync_safe_id "$_seq" \
				|| { log_warn "sync: recall unsafe id gid=$_gid seq=$_seq"; return 0; }
			# New format: QQ msg -> DC ID (DC->QQ forward)
			_fwd_map="$_STATE_DIR/msg-map/$_gid/$_seq"
			if [ -f "$_fwd_map" ]; then
				read -r _dec_mid _dec_cid < "$_fwd_map" 2>/dev/null
				rm -f "$_fwd_map"
				if [ -n "$_dec_mid" ] && [ "$_dec_mid" != "NOTFOUND" ]; then
					dc_message_delete "${_dec_cid:-}" "$_dec_mid" >/dev/null 2>/dev/null && log_info "sync: recall qq->dc OK $_dec_mid"
					_dc_rev="$_STATE_DIR/msg-map-rev/discord/$_dec_mid"
					if [ -f "$_dc_rev" ]; then
						while read -r _d_tgt _d_chat _d_mid; do
							case "$_d_chat" in
								telegram/*)
									_tchat="${_d_chat#telegram/}"
									tg_deleteMessage "$_tchat" "$_d_mid" >/dev/null 2>/dev/null && log_info "sync: recall qq->tg OK tg=$_tchat msg=$_d_mid"
									;;
							esac
						done < "$_dc_rev"
						rm -f "$_dc_rev"
					fi
				fi
			# Old format: QQ msg -> TG/DC (QQ->TG/DC forward, backwards compat)
			else
				_map="$_STATE_DIR/msg-map-rev/$_gid/$_seq"
				if [ -f "$_map" ]; then
					while read -r _tpf_val _tid1 _tid2; do
						if [ -z "$_tid2" ]; then
							_tid2="$_tid1"; _tid1="$_tpf_val"; _tpf_val="telegram"
						fi
						_ok=0
						case "$_tpf_val" in
							telegram) tg_deleteMessage "$_tid1" "$_tid2" >/dev/null 2>/dev/null && _ok=1 ;;
							discord) dc_message_delete "$_tid1" "$_tid2" >/dev/null 2>/dev/null && _ok=1 ;;
							qqbot) qqbot_message_recall_group "$_tid1" "$_tid2" >/dev/null 2>/dev/null && _ok=1 ;;
						esac
						if [ $_ok -eq 1 ]; then
							log_info "sync: recall qq->$_tpf_val OK gid=$_gid seq=$_seq"
						else
							log_err "sync: recall qq->$_tpf_val FAIL: $_ERROR"
						fi
						rm -f "$_STATE_DIR/msg-map/$_tid1/$_tid2" 2>/dev/null
					done < "$_map"
					rm -f "$_map"
				else
					log_debug "sync: recall no rev-map $_gid/$_seq"
				fi
			fi
		fi
		return 0
	fi

	# Loop prevention 2: sender is the bot itself
	case "$_pf" in
		qq) [ "$_uid" = "$QQ_BOT_ID" ] && return 0 ;;
		telegram)
			_fid="$(json_get "$_raw" from 2>/dev/null)" || _fid=""
			if [ -n "$_fid" ] && [ "$_fid" != "NOTFOUND" ]; then
				_fid_id="$(json_get "$_fid" id 2>/dev/null)" || _fid_id=""
				[ "$_fid_id" = "$TG_BOT_ID" ] && return 0
			fi
			;;
	esac

	# Decode \uXXXX to UTF-8, then normalize newlines (TG/DC can't render them)
	_txt="$(utf8_decode "$_txt")"
	_txt_safe="$(printf '%b' "$_txt")"
	_txt_dc="$(printf '%s' "$_txt_safe" | awk 1 ORS=' ')"

	# Map non-message events to descriptive text
	case "$_evt" in
		group_nudge) _txt="[戳一戳]" ;;
		member_join) _txt="[新成员加入]" ;;
		member_leave) _txt="[成员离开]" ;;
		friend_request) _txt="[好友请求]" ;;
		message_recall) _txt="[撤回消息]" ;;
	esac

	_conf="${_SYNC_CONF:-$_HB/etc/sync.conf}"
	if [ ! -f "$_conf" ]; then
		log_debug "sync: no conf at $_conf"
		return 0
	fi

	# Build prefixed text with sender attribution and emoji icon
	_sender="$(_sync_get_sender "$_pf" "$_raw")"
	_sender="$(utf8_decode "$_sender")"
	case "$_pf" in qq) _icon="🐧" ;; telegram) _icon="✈️" ;; discord) _icon="👾" ;; qqbot) _icon="🅠" ;; *) _icon="[$_pf]" ;; esac
	_text="$_icon $_sender: $_txt"
		_text_safe="$_icon $_sender: $_txt_safe"
		_text_dc="$_icon $_sender: $_txt_dc"

	# Extract source ID for config lookup
	_src_id="$(_sync_source_id "$_pf" "$_raw")"
	if [ -z "$_src_id" ]; then
		log_debug "sync: no src_id pf=$_pf"
		return 0
	fi
	# The id half becomes a directory under msg-map-rev.
	_sync_safe_id "${_src_id#*/}" \
		|| { log_warn "sync: unsafe src_id ($_src_id), dropped"; return 0; }

	log_info "sync: $_pf $_src_id → $_txt"
	log_debug "sync: raw_segs=$(json_get "$_raw" segments 2>/dev/null)"

	# Pre-build platform-specific payloads
	_segs="$(qq_text_segments "$_text")"
	_dc_body="$(json_obj "content" "$_text_dc")"

	_found=0
	while IFS='=' read -r _src _tgt; do
		case "$_src" in \#*|"") continue ;; esac
		_spf="${_src%%/*}"
		_sid="${_src#*/}"
		[ "$_spf" != "$_pf" ] && continue
		[ "$_sid" != "$_src_id" ] && continue

		_tpf="${_tgt%%/*}"
		_tid="${_tgt#*/}"
		_found=1

		case "$_tpf" in
		telegram)
			_tcid="${_tid%%/*}"
			_tthr="${_tid#*/}"
			[ "$_tthr" = "$_tcid" ] && _tthr=""
			if [ -n "$_tthr" ]; then
				_body="$(json_obj "chat_id" "$_tcid" "text" "$_text_safe" "message_thread_id" "$_tthr")"
			else
				_body="$(json_obj "chat_id" "$_tcid" "text" "$_text_safe")"
			fi
				_tg_api "sendMessage" "$_body" "sync.tg" > "/tmp/sync-tg-resp-$$" || { log_err "sync: $_pf→tg FAIL: $_ERROR"; _resp=""; }
				_resp="$(cat "/tmp/sync-tg-resp-$$" 2>/dev/null)"; rm -f "/tmp/sync-tg-resp-$$"
				if [ -n "$_resp" ] && [ "$_resp" != "NOTFOUND" ]; then
					_tmid="$(json_get "$_resp" message_id 2>/dev/null)" || _tmid=""
					_rseq="$(_sync_src_msgid "$_pf" "$_raw")"
					if [ -n "$_tmid" ] && [ -n "$_rseq" ]; then
						mkdir -p "$_STATE_DIR/msg-map/$_tcid" && chmod 2750 "$_STATE_DIR/msg-map/$_tcid" 2>/dev/null
						chmod 2750 "$_STATE_DIR/msg-map/$_tcid" 2>/dev/null
						echo "${_src_id#*/} $_rseq" > "$_STATE_DIR/msg-map/$_tcid/$_tmid"
						chmod 640 "$_STATE_DIR/msg-map/$_tcid/$_tmid" 2>/dev/null
						mkdir -p "$_STATE_DIR/msg-map-rev/${_src_id#*/}" && chmod 2750 "$_STATE_DIR/msg-map-rev/${_src_id#*/}" 2>/dev/null
						chmod 2750 "$_STATE_DIR/msg-map-rev/${_src_id#*/}" 2>/dev/null
						echo "telegram $_tcid $_tmid" >> "$_STATE_DIR/msg-map-rev/${_src_id#*/}/$_rseq"
						chmod 640 "$_STATE_DIR/msg-map-rev/${_src_id#*/}/$_rseq" 2>/dev/null
					fi
					log_info "sync: $_pf→tg OK"
				else
					log_err "sync: $_pf→tg FAIL: $_ERROR"
				fi
			# Forward media (QQ bot→TG)
			if [ "$_pf" = "qqbot" ]; then
				_sync_qqbot_media_to_tg "$_raw" "$_tcid" "$_tthr" "$_sender"
			fi
			# Forward images (QQ→TG)
			if [ "$_pf" = "qq" ]; then
				_sync_qq_images_to_tg "$_raw" "$_tcid" "$_tthr" "$_sender"
				_sync_qq_record_to_tg "$_raw" "$_tcid" "$_tthr" "$_sender"
				_sync_qq_video_to_tg "$_raw" "$_tcid" "$_tthr" "$_sender"
				_sync_qq_files_to_tg "$_raw" "$_tcid" "$_tthr" "$_sender" "${_src_id#*/}"
			fi
			;;
		qqbot)
			# QQ official bot as the destination. `_text_safe` keeps real newlines
			# plus the source icon/sender prefix (json_obj escapes them), and the
			# reply id is stored in the reverse map so a recall on the source
			# platform deletes the forwarded copy.
			_qq_src_seq="$(_sync_src_msgid "$_pf" "$_raw")"
			case "$_tid" in
			group/*)
				_qq_gid="${_tid#group/}"
				_qq_resp="$(qqbot_message_send_group "$_qq_gid" "$_text_safe" 2>/dev/null)" || _qq_resp=""
				if [ -n "$_qq_resp" ] && [ "$_qq_resp" != "NOTFOUND" ]; then
					log_info "sync: $_pf→qqbot group $_qq_gid OK"
					_qq_mid="$(json_get "$_qq_resp" id 2>/dev/null)" || _qq_mid=""
					if [ -n "$_qq_mid" ] && [ -n "$_qq_src_seq" ] && [ "$_qq_mid" != "NOTFOUND" ] && [ "$_qq_src_seq" != "NOTFOUND" ]; then
						# Reverse maps are keyed by the bare source chat id, matching
						# the qq/telegram recall paths.
						_qq_rkey="${_src_id#*/}"
						mkdir -p "$_STATE_DIR/msg-map-rev/$_qq_rkey"
						chmod 2750 "$_STATE_DIR/msg-map-rev/$_qq_rkey" 2>/dev/null
						echo "qqbot $_qq_gid $_qq_mid" >> "$_STATE_DIR/msg-map-rev/$_qq_rkey/$_qq_src_seq"
						chmod 640 "$_STATE_DIR/msg-map-rev/$_qq_rkey/$_qq_src_seq" 2>/dev/null
					fi
				else
					log_err "sync: $_pf→qqbot group $_qq_gid FAIL: $_ERROR"
				fi
				;;
			private/*)
				_qq_oid="${_tid#private/}"
				if qqbot_message_send_c2c "$_qq_oid" "$_text_safe" >/dev/null 2>/dev/null; then
					log_info "sync: $_pf→qqbot private $_qq_oid OK"
				else
					log_err "sync: $_pf→qqbot private $_qq_oid FAIL: $_ERROR"
				fi
				;;
			channel/*)
				_qq_ch="${_tid#channel/}"
				if qqbot_message_send_channel "$_qq_ch" "$_text_safe" >/dev/null 2>/dev/null; then
					log_info "sync: $_pf→qqbot channel $_qq_ch OK"
				else
					log_err "sync: $_pf→qqbot channel $_qq_ch FAIL: $_ERROR"
				fi
				;;
			esac
			;;
		qq)
			case "$_tid" in
			group/*)
				_gid="${_tid#group/}"
				qq_message_send_group "$_gid" "$_segs" > "/tmp/sync-qq-resp-$$" 2>/dev/null || { log_err "sync: $_pf→qq FAIL: $_ERROR"; _resp=""; }
				_resp="$(cat "/tmp/sync-qq-resp-$$" 2>/dev/null)"; rm -f "/tmp/sync-qq-resp-$$"
				if [ -n "$_resp" ] && [ "$_resp" != "NOTFOUND" ]; then
					_rseq="$(json_get "$_resp" message_seq 2>/dev/null)" || _rseq=""
					_tmid="$(json_get "$_raw" message_id 2>/dev/null)" || _tmid=""
					_tchat="$(json_get "$_raw" chat 2>/dev/null)" || _tchat=""
					_tcid="$(json_get "$_tchat" id 2>/dev/null)" || _tcid=""
					if [ -n "$_tmid" ] && [ -n "$_rseq" ] && [ -n "$_tcid" ]; then
						mkdir -p "$_STATE_DIR/msg-map-rev/$_gid"
						chmod 2750 "$_STATE_DIR/msg-map-rev/$_gid" 2>/dev/null
						echo "telegram $_tcid $_tmid" >> "$_STATE_DIR/msg-map-rev/$_gid/$_rseq"
						echo "$_gid $_rseq" > "/tmp/sync-tg-qq-$$"
						mkdir -p "$_STATE_DIR/msg-map/$_tcid"
						chmod 2750 "$_STATE_DIR/msg-map/$_tcid" 2>/dev/null
						echo "$_gid $_rseq" > "$_STATE_DIR/msg-map/$_tcid/$_tmid"
						chmod 640 "$_STATE_DIR/msg-map/$_tcid/$_tmid" 2>/dev/null
					fi
					log_info "sync: $_pf→qq group $_gid OK"
				else
					log_err "sync: $_pf→qq group $_gid FAIL: $_ERROR"
				fi
				# Forward photo (TG→QQ)
				if [ "$_pf" = "telegram" ]; then
					_sync_tg_voice_to_qq "$_raw" "$_gid"
					_sync_tg_audio_to_qq "$_raw" "$_gid"
					_sync_tg_video_to_qq "$_raw" "$_gid"
					_sync_tg_photo_to_qq "$_raw" "$_gid"
					_sync_tg_sticker_to_qq "$_raw" "$_gid"
					_sync_tg_animation_to_qq "$_raw" "$_gid"
					_ani="$(json_get "$_raw" animation 2>/dev/null)" || _ani=""; [ -z "$_ani" ] || [ "$_ani" = "NOTFOUND" ] && _sync_tg_document_to_qq "$_raw" "$_gid"
				fi
				;;
			private/*)
				_pid="${_tid#private/}"
				if qq_message_send_private "$_pid" "$_segs" >/dev/null; then
					log_info "sync: $_pf→qq private $_pid OK"
				else
					log_err "sync: $_pf→qq private $_pid FAIL: $_ERROR"
				fi
				;;
			esac
			;;
		discord)
			_dc_resp="$(dc_message_create "$_tid" "$_dc_body" 2>/dev/null)" || _dc_resp=""
			if [ -n "$_dc_resp" ] && [ "$_dc_resp" != "NOTFOUND" ]; then
				log_info "sync: $_pf→dc text OK"
				_dmid="$(json_get "$_dc_resp" id 2>/dev/null)" || _dmid=""
				_rseq="$(_sync_src_msgid "$_pf" "$_raw")"
				if [ -n "$_dmid" ] && [ -n "$_rseq" ] && [ "$_dmid" != "NOTFOUND" ] && [ "$_rseq" != "NOTFOUND" ]; then
					mkdir -p "$_STATE_DIR/msg-map/$_tid" && chmod 2750 "$_STATE_DIR/msg-map/$_tid" 2>/dev/null
					echo "${_src_id#*/} $_rseq" > "$_STATE_DIR/msg-map/$_tid/$_dmid"
					chmod 640 "$_STATE_DIR/msg-map/$_tid/$_dmid" 2>/dev/null
					mkdir -p "$_STATE_DIR/msg-map-rev/${_src_id#*/}" && chmod 2750 "$_STATE_DIR/msg-map-rev/${_src_id#*/}" 2>/dev/null
					echo "discord $_tid $_dmid" >> "$_STATE_DIR/msg-map-rev/${_src_id#*/}/$_rseq"
					# If source is TG, also append to QQ rev-map
					if [ "$_pf" = "telegram" ] && [ -f "/tmp/sync-tg-qq-$$" ]; then
						read -r _qq_gid _qq_seq < "/tmp/sync-tg-qq-$$"
						echo "discord $_tid $_dmid" >> "$_STATE_DIR/msg-map-rev/$_qq_gid/$_qq_seq"
						chmod 640 "$_STATE_DIR/msg-map-rev/$_qq_gid/$_qq_seq" 2>/dev/null
						rm -f "/tmp/sync-tg-qq-$$"
					fi
					chmod 640 "$_STATE_DIR/msg-map-rev/${_src_id#*/}/$_rseq" 2>/dev/null
				fi
			else
				log_err "sync: $_pf→dc FAIL: $_ERROR"
			fi
			# Forward media (QQ bot→DC)
			if [ "$_pf" = "qqbot" ]; then
				_sync_qqbot_media_to_dc "$_raw" "$_tid" "" "$_sender"
			fi
			# Forward media (QQ→DC)
			if [ "$_pf" = "qq" ]; then
				_sync_qq_images_to_dc "$_raw" "$_tid" "$_sender"
				_sync_qq_record_to_dc "$_raw" "$_tid" "$_sender"
				_sync_qq_video_to_dc "$_raw" "$_tid" "$_sender"
				_sync_qq_files_to_dc "$_raw" "$_tid" "$_sender" "${_src_id#*/}"
			fi
			# Forward media (TG→DC)
			if [ "$_pf" = "telegram" ]; then
				_sync_tg_photo_to_dc "$_raw" "$_tid" "$_sender"
				_sync_tg_sticker_to_dc "$_raw" "$_tid" "$_sender"
				_sync_tg_animation_to_dc "$_raw" "$_tid" "$_sender"
				_sync_tg_voice_to_dc "$_raw" "$_tid" "$_sender"
				_sync_tg_video_to_dc "$_raw" "$_tid" "$_sender"
				_sync_tg_document_to_dc "$_raw" "$_tid" "$_sender"
			fi
			;;
		esac
	done < "$_conf"

	[ $_found -eq 0 ] && log_debug "sync: no match for $_pf $_src_id"
	return 0
}

