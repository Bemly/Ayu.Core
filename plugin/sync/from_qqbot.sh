# plugin/sync/from_qqbot.sh — relay QQ official-bot media to TG / DC
#
# Official webhook events carry media only as `attachments` (url + content_type,
# no local path, no segments), so each item is downloaded once and re-uploaded
# through the existing multipart helpers. Relay is best-effort: a failed item is
# logged and the text message still goes out.

# _qqbot_attachments_lines <raw d> → one attachment object per line
_qqbot_attachments_lines() {
	_qbl_raw="$(json_get "$1" attachments 2>/dev/null)" || _qbl_raw=""
	case "$_qbl_raw" in ''|NOTFOUND|null|'[]') return 0 ;; esac
	printf '%s' "$_qbl_raw" | sed 's/},{/}\
{/g'
}

# _qqbot_attach_url <item> — voice prefers the WAV transcode (SILK is useless)
_qqbot_attach_url() {
	_qbu_ct="$(json_get "$1" content_type 2>/dev/null)" || _qbu_ct=""
	_qbu_u="$(json_get "$1" url 2>/dev/null)" || _qbu_u=""
	case "$_qbu_ct" in
		voice*|audio/*)
			_qbu_w="$(json_get "$1" voice_wav_url 2>/dev/null)" || _qbu_w=""
			case "$_qbu_w" in ''|NOTFOUND|null) : ;; *) _qbu_u="$_qbu_w" ;; esac
			;;
	esac
	case "$_qbu_u" in NOTFOUND|null) _qbu_u="" ;; esac
	# The webhook JSON escapes '&' as \u0026 in attachment URLs. Left encoded,
	# the CDN sees a single broken parameter pair ("?appid=..\u0026fileid=..")
	# and answers {"retcode":-5503010,"retmsg":"invalid rkey"} instead of bytes.
	[ -n "$_qbu_u" ] && _qbu_u="$(utf8_decode "$_qbu_u")"
	printf '%s' "$_qbu_u"
}

# _qqbot_attach_label <content_type> → short Chinese label for captions
_qqbot_attach_label() {
	case "$1" in
		image/*)       printf '图片' ;;
		video/*)       printf '视频' ;;
		voice*|audio/*) printf '语音' ;;
		*)             printf '文件' ;;
	esac
}

# _qqbot_attach_mime <content_type> <filename> → MIME for the upload part
_qqbot_attach_mime() {
	case "$1" in
		image/gif)  printf 'image/gif' ;;
		image/png)  printf 'image/png' ;;
		image/webp) printf 'image/webp' ;;
		image/*)    printf 'image/jpeg' ;;
		video/*)    printf 'video/mp4' ;;
		voice*|audio/*) printf 'audio/wav' ;;
		*)
			case "$2" in
				*.pdf|*.PDF) printf 'application/pdf' ;;
				*.zip|*.ZIP) printf 'application/zip' ;;
				*.txt|*.TXT|*.md) printf 'text/plain' ;;
				*) printf 'application/octet-stream' ;;
			esac
			;;
	esac
}

# _qqbot_attach_ext <content_type> → file extension derived from the MIME type
# The official bot API often returns an extension-less filename (an opaque id),
# and Discord only renders an inline preview when the name carries a matching
# extension; without it the picture arrives as a downloadable file.
_qqbot_attach_ext() {
	case "$1" in
		image/gif)             printf 'gif' ;;
		image/png)             printf 'png' ;;
		image/webp)            printf 'webp' ;;
		image/jpeg|image/jpg|image/*) printf 'jpg' ;;
		video/*)               printf 'mp4' ;;
		voice*|audio/*)        printf 'wav' ;;
		*)                     printf '' ;;
	esac
}

# _qqbot_filename_with_ext <content_type> <filename>
# Keep a real name untouched; append the MIME-derived suffix when it has none.
_qqbot_filename_with_ext() {
	_qfe_ct="$1" _qfe_fn="$2"
	case "$_qfe_fn" in
		*.*) printf '%s' "$_qfe_fn"; return 0 ;;
	esac
	_qfe_ext="$(_qqbot_attach_ext "$_qfe_ct")"
	if [ -n "$_qfe_ext" ]; then
		printf '%s.%s' "$_qfe_fn" "$_qfe_ext"
	else
		printf '%s' "$_qfe_fn"
	fi
}

# _qqbot_sniff_ct <path> → content_type from magic bytes, "" when unknown.
# Some events omit content_type entirely; sniffing keeps them on the image path
# instead of falling back to sendDocument.
_qqbot_sniff_ct() {
	_qsc_magic="$(dd if="$1" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
	case "$_qsc_magic" in
		89504e47*) printf 'image/png' ;;
		ffd8ff*)   printf 'image/jpeg' ;;
		47494638*) printf 'image/gif' ;;
		52494646*)
			[ "$(dd if="$1" bs=1 skip=8 count=4 2>/dev/null)" = "WEBP" ] && printf 'image/webp'
			;;
	esac
}

# _qqbot_bad_download <path> — 0 when the saved body is an error document.
# A rejected CDN request still returns HTTP 200 with a small JSON error, so
# http_get_file "succeeds" and the 58-byte {"retcode":...} blob used to be
# forwarded to TG/DC as if it were the picture. Real media never starts with '{'
# and is bigger than a few dozen bytes, hence the cheap shape test.
_qqbot_bad_download() {
	_qbd_sz="$(wc -c <"$1" 2>/dev/null | tr -d ' ')"
	case "$_qbd_sz" in ''|*[!0-9]*) return 1 ;; esac
	[ "$_qbd_sz" -gt 0 ] || return 1
	[ "$_qbd_sz" -lt 4096 ] || return 1
	[ "$(head -c 1 "$1" 2>/dev/null)" = "{" ] || return 1
	grep -q '"retcode"\|"retmsg"' "$1" 2>/dev/null || return 1
	return 0
}

# _sync_qqbot_media <tg|dc> <raw d> <cid> <thread> <sender>
# Returns 0 if at least one attachment was relayed.
_sync_qqbot_media() {
	_qbm_pf="$1" _qbm_raw="$2" _qbm_cid="$3" _qbm_thr="$4" _qbm_sender="$5"
	_qbm_items="$(_qqbot_attachments_lines "$_qbm_raw")"
	[ -n "$_qbm_items" ] || return 1
	_qbm_n=0 _qbm_ok=0
	IFS='
'
	for _qbm_it in $_qbm_items; do
		_qbm_n=$(( _qbm_n + 1 ))
		[ -n "$_qbm_it" ] || continue
		_qbm_ct="$(json_get "$_qbm_it" content_type 2>/dev/null)" || _qbm_ct=""
		_qbm_fn="$(json_get "$_qbm_it" filename 2>/dev/null)" || _qbm_fn=""
		[ -n "$_qbm_fn" ] && _qbm_fn="$(utf8_decode "$_qbm_fn")"
		case "$_qbm_fn" in ''|NOTFOUND|null) _qbm_fn="qqbot-${_qbm_n}" ;; esac
		_qbm_url="$(_qqbot_attach_url "$_qbm_it")"
		if [ -z "$_qbm_url" ]; then
			log_err "sync: qqbot→$_qbm_pf item $_qbm_n has no url (ct=$_qbm_ct)"
			continue
		fi
		mkdir -p /tmp/img 2>/dev/null
		_qbm_tmp="/tmp/img/sync-qqbot-$$-$_qbm_n"
		if ! http_get_file "$_qbm_url" "$_qbm_tmp"; then
			log_err "sync: qqbot→$_qbm_pf download FAIL ct=$_qbm_ct: $_ERROR"
			rm -f "$_qbm_tmp"
			continue
		fi
		if _qqbot_bad_download "$_qbm_tmp"; then
			log_err "sync: qqbot→$_qbm_pf item $_qbm_n CDN error body size=$(wc -c <"$_qbm_tmp" 2>/dev/null | tr -d ' '): $(tr '\r\n\t' '   ' <"$_qbm_tmp" 2>/dev/null | cut -c1-200)"
			rm -f "$_qbm_tmp"
			continue
		fi
		# content_type is sometimes absent / generic — sniff the bytes so a
		# picture is not downgraded to sendDocument just because QQ omitted it.
		case "$_qbm_ct" in
			''|NOTFOUND|null|application/octet-stream)
				_qbm_sniff="$(_qqbot_sniff_ct "$_qbm_tmp")"
				if [ -n "$_qbm_sniff" ]; then
					_qbm_ct="$_qbm_sniff"
					log_debug "sync: qqbot→$_qbm_pf item $_qbm_n sniffed ct=$_qbm_ct"
				fi
				;;
		esac
		_qbm_fn="$(_qqbot_filename_with_ext "$_qbm_ct" "$_qbm_fn")"
		_qbm_mime="$(_qqbot_attach_mime "$_qbm_ct" "$_qbm_fn")"
		_qbm_cap="🅠 $_qbm_sender: [$(_qqbot_attach_label "$_qbm_ct")]"
		log_info "sync: qqbot→$_qbm_pf item $_qbm_n ct=$_qbm_ct fn=$_qbm_fn size=$(wc -c <"$_qbm_tmp" 2>/dev/null | tr -d ' ')"

		if [ "$_qbm_pf" = "dc" ]; then
			if _sync_dc_multipart "$_qbm_cid" "$_qbm_tmp" "$_qbm_fn" "$_qbm_mime" "$_qbm_cap"; then
				_qbm_ok=$(( _qbm_ok + 1 ))
				log_info "sync: qqbot→dc ${_qbm_ct} OK"
			else
				log_err "sync: qqbot→dc ${_qbm_ct} FAIL: $_ERROR"
			fi
		else
			case "$_qbm_ct" in
				image/gif)      _qbm_method=sendAnimation _qbm_field=animation ;;
				image/*)        _qbm_method=sendPhoto     _qbm_field=photo ;;
				video/*)        _qbm_method=sendVideo     _qbm_field=video ;;
				voice*|audio/*) _qbm_method=sendAudio     _qbm_field=audio ;;
				*)              _qbm_method=sendDocument  _qbm_field=document ;;
			esac
			# Telegram caps sendPhoto at 10 MB — larger stills become documents
			if [ "$_qbm_method" = "sendPhoto" ] && [ "$(wc -c <"$_qbm_tmp" 2>/dev/null)" -gt 10000000 ] 2>/dev/null; then
				_qbm_method=sendDocument _qbm_field=document
			fi
			if _sync_tg_multipart "$_qbm_cid" "$_qbm_thr" "$_qbm_tmp" "$_qbm_fn" \
				"$_qbm_method" "$_qbm_field" "$_qbm_mime" "$_qbm_cap"; then
				_qbm_ok=$(( _qbm_ok + 1 ))
				log_info "sync: qqbot→tg ${_qbm_ct} OK"
			else
				log_err "sync: qqbot→tg ${_qbm_ct} FAIL: $_ERROR"
			fi
		fi
		rm -f "$_qbm_tmp"
	done
	log_info "sync: qqbot→$_qbm_pf media sent=$_qbm_ok/$_qbm_n"
	[ "$_qbm_ok" -gt 0 ] && return 0
	return 1
}

# Thin wrappers keep the call sites in handler.sh readable.
_sync_qqbot_media_to_tg() { _sync_qqbot_media tg "$@"; }
_sync_qqbot_media_to_dc() { _sync_qqbot_media dc "$@"; }

# The QQ bot API layer is only loaded by its own webhook entry point; sync may
# run under a router that never touched it, so load the send helpers lazily.
if [ -z "${_QQBOT_SEND_LOADED:-}" ]; then
	[ -f "$_HB/adapter/qqbot/core.sh" ] && . "$_HB/adapter/qqbot/core.sh"
	[ -f "$_HB/adapter/qqbot/message.sh" ] && . "$_HB/adapter/qqbot/message.sh"
	_QQBOT_SEND_LOADED=1
fi
