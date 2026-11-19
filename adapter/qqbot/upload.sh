# adapter/qqbot/upload.sh — chunked upload + media-image helpers
#
# One code path serves both scenes; only the path prefix differs:
#   group → /v2/groups/{group_openid}/...
#   c2c   → /v2/users/{user_openid}/...
#
# Flow (official 富媒体使用说明 / v2_groups_group_id_upload_prepare /
# v2_groups_group_id_upload_part_finish):
#   1. POST {prefix}/upload_prepare
#        {file_type,file_size,file_name,md5,sha1,md5_10m}
#        → {upload_id, block_size, parts[{index,presigned_url,block_size}], upload_config}
#   2. for each part: dd the slice → PUT presigned_url → POST {prefix}/upload_part_finish
#        {upload_id, part_index, block_size, md5}
#      注意：每片单独 finish，不是全部上传完再一次性提交。
#   3. POST {prefix}/files {file_type, file_name, upload_id, srv_send_msg}
#        → {file_uuid, file_info, ttl, id, raw_url}
#
# media images（Markdown 图文）走另一套三步：
#   POST /v2/media-images/prepare → PUT presigned_url → POST /v2/media-images/complete
#   得到 qqbot-media://image/v1/<token>，可直接写进 markdown 的 ![]()。
#
# Everything is shell + busybox applets (md5sum/sha1sum/head/dd): no jq, no
# python, no curl — the container is busybox:musl.

[ "${_QQBOT_UPLOAD_SH:-0}" = "1" ] && return 0
_QQBOT_UPLOAD_SH=1

. "$_HB/adapter/qqbot/core.sh"

# ---- small file helpers -------------------------------------------------

_qqbot_file_size() { wc -c <"$1" 2>/dev/null | tr -d ' '; }
_qqbot_md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
_qqbot_sha1() { sha1sum "$1" 2>/dev/null | cut -d' ' -f1; }
# md5_10m = MD5 of the first 10002432 bytes; equal to the whole-file md5 for
# anything at or below that size, so head is always safe to run.
_qqbot_md5_10m() { head -c 10002432 "$1" 2>/dev/null | md5sum | cut -d' ' -f1; }

# _qqbot_file_type <path> → 1 image, 2 video, 3 voice, 4 file
# Uses message.sh's classifier when it is already loaded, otherwise repeats the
# suffix mapping so upload.sh works standalone (group.sh only sources core).
_qqbot_file_type() {
	if command -v qqbot_file_type_of >/dev/null 2>&1; then
		qqbot_file_type_of "$1"
		return 0
	fi
	case "$1" in
		*.png|*.PNG|*.jpg|*.JPG|*.jpeg|*.JPEG|*.gif|*.GIF|*.webp|*.WEBP) printf 1 ;;
		*.mp4|*.MP4|*.mov|*.MOV|*.mkv|*.MKV|*.avi|*.AVI) printf 2 ;;
		*.silk|*.SILK|*.amr|*.AMR|*.mp3|*.MP3|*.wav|*.WAV|*.ogg|*.OGG) printf 3 ;;
		*) printf 4 ;;
	esac
}

# _qqbot_image_ct <path> → MIME (png/jpeg/gif/webp only)
_qqbot_image_ct() {
	case "$1" in
		*.png|*.PNG)   printf 'image/png' ;;
		*.jpg|*.JPG|*.jpeg|*.JPEG) printf 'image/jpeg' ;;
		*.gif|*.GIF)   printf 'image/gif' ;;
		*.webp|*.WEBP) printf 'image/webp' ;;
		*) return 1 ;;
	esac
}

# _qqbot_scene_path <group|c2c> <openid> → /v2/groups/<id> or /v2/users/<id>
_qqbot_scene_path() {
	case "$1" in
		group) printf '/v2/groups/%s' "$(qqbot_seg "$2")" ;;
		c2c)   printf '/v2/users/%s' "$(qqbot_seg "$2")" ;;
		*)     return 1 ;;
	esac
}

# ---- upload_prepare -----------------------------------------------------

# qqbot_upload_prepare <scene> <openid> <file_type> <file_size> <file_name> <md5> <sha1> <md5_10m>
qqbot_upload_prepare() {
	_qup_p="$(_qqbot_scene_path "$1" "$2")" || return 1
	_qup_b="$(json_obj file_type "$3" file_size "$4" file_name "$5" md5 "$6" sha1 "$7" md5_10m "$8")"
	_qqbot_api POST "$_qup_p/upload_prepare" "$_qup_b" "qqbot.$1.upload_prepare"
}

# qqbot_upload_prepare_file <scene> <openid> <path> [file_type] [file_name]
# Fills every hash field the API marks required.
qqbot_upload_prepare_file() {
	_qupf_f="$3"
	[ -f "$_qupf_f" ] || { _ERROR="qqbot.upload: no such file $_qupf_f"; return 1; }
	_qupf_ty="${4:-$(_qqbot_file_type "$_qupf_f")}"
	_qupf_n="${5:-${_qupf_f##*/}}"
	_qupf_sz="$(_qqbot_file_size "$_qupf_f")"
	_qupf_md5="$(_qqbot_md5 "$_qupf_f")"
	_qupf_sha1="$(_qqbot_sha1 "$_qupf_f")"
	_qupf_md510="$(_qqbot_md5_10m "$_qupf_f")"
	if [ -z "$_qupf_md5" ] || [ -z "$_qupf_sha1" ]; then
		_ERROR="qqbot.upload: cannot hash $_qupf_f"
		return 1
	fi
	qqbot_upload_prepare "$1" "$2" "$_qupf_ty" "$_qupf_sz" "$_qupf_n" \
		"$_qupf_md5" "$_qupf_sha1" "$_qupf_md510"
}

# ---- upload_part_finish -------------------------------------------------

# qqbot_upload_part_finish <scene> <openid> <upload_id> <part_index> <block_size> <md5>
qqbot_upload_part_finish() {
	_quf_p="$(_qqbot_scene_path "$1" "$2")" || return 1
	_quf_b="$(json_obj upload_id "$3" part_index "$4" block_size "$5" md5 "$6")"
	_qqbot_api POST "$_quf_p/upload_part_finish" "$_quf_b" "qqbot.$1.upload_part_finish"
}

# ---- merge --------------------------------------------------------------

# qqbot_upload_concurrency — 官方 upload_config.concurrency 的并发度
# hush 没有 job control（`&` + `wait` 在 busybox hush 下不可靠），分片仍串行上传；
# 这里保留取值入口，供后续 server 模式（GET 控制面）调度使用，属覆盖率占位。
qqbot_upload_concurrency() { printf '%s' "${QQBOT_UPLOAD_CONCURRENCY:-1}"; }

# qqbot_upload_merge <scene> <openid> <file_type> <file_name> <upload_id> [srv_send_msg]
qqbot_upload_merge() {
	_qum_p="$(_qqbot_scene_path "$1" "$2")" || return 1
	_qum_b="$(json_obj file_type "$3" file_name "$4" upload_id "$5" srv_send_msg "${6:-false}")"
	_qqbot_api POST "$_qum_p/files" "$_qum_b" "qqbot.$1.upload_merge"
}

# ---- full chunked flow --------------------------------------------------

# qqbot_upload_file <scene> <openid> <path> [file_type] [file_name] [srv_send_msg]
# → the /files response (contains file_info / file_uuid / ttl / id)
qqbot_upload_file() {
	_qu_f="$3"
	[ -f "$_qu_f" ] || { _ERROR="qqbot.upload: no such file $_qu_f"; return 1; }
	_qu_ty="${4:-$(_qqbot_file_type "$_qu_f")}"
	_qu_n="${5:-${_qu_f##*/}}"
	_qu_srv="${6:-false}"
	_qu_sz="$(_qqbot_file_size "$_qu_f")"

	_qu_prep="$(qqbot_upload_prepare_file "$1" "$2" "$_qu_f" "$_qu_ty" "$_qu_n")" || return 1
	_qu_id="$(json_get "$_qu_prep" upload_id 2>/dev/null)" || _qu_id=""
	_qu_block="$(json_get "$_qu_prep" block_size 2>/dev/null)" || _qu_block=""
	_qu_parts="$(json_get "$_qu_prep" parts 2>/dev/null)" || _qu_parts=""
	case "$_qu_id" in ''|NOTFOUND|null)
		_ERROR="qqbot.upload: no upload_id in response body=$(_qqbot_resp_digest "$_qu_prep")"
		_qqbot_note_err "$_ERROR"; return 1 ;;
	esac
	_qu_cfg="$(json_get "$_qu_prep" upload_config 2>/dev/null)" || _qu_cfg=""
	QQBOT_UPLOAD_CONCURRENCY="$(json_get "$_qu_cfg" concurrency 2>/dev/null)" || QQBOT_UPLOAD_CONCURRENCY=""
	case "$QQBOT_UPLOAD_CONCURRENCY" in ''|*[!0-9]*|NOTFOUND|null) QQBOT_UPLOAD_CONCURRENCY=1 ;; esac
	QQBOT_UPLOAD_RETRY_TIMEOUT="$(json_get "$_qu_cfg" retry_timeout 2>/dev/null)" || QQBOT_UPLOAD_RETRY_TIMEOUT=""
	case "$QQBOT_UPLOAD_RETRY_TIMEOUT" in ''|*[!0-9]*|NOTFOUND|null) QQBOT_UPLOAD_RETRY_TIMEOUT=300 ;; esac
	QQBOT_UPLOAD_RETRY_DELAY_OVERRIDE="$(json_get "$_qu_cfg" retry_delay 2>/dev/null)" || QQBOT_UPLOAD_RETRY_DELAY_OVERRIDE=""
	case "$QQBOT_UPLOAD_RETRY_DELAY_OVERRIDE" in ''|*[!0-9]*|NOTFOUND|null) QQBOT_UPLOAD_RETRY_DELAY_OVERRIDE="" ;; esac
	_qu_n_parts="$(json_arr_len "$_qu_parts" 2>/dev/null)" || _qu_n_parts=0
	case "$_qu_n_parts" in ''|*[!0-9]*|0)
		_ERROR="qqbot.upload: empty parts list (size=$_qu_sz block=$_qu_block)"
		_qqbot_note_err "$_ERROR"; return 1 ;;
	esac

	_qu_part="/tmp/qqbot-part.$$"
	_qu_i=0
	while [ "$_qu_i" -lt "$_qu_n_parts" ]; do
		_qu_it="$(json_arr_at "$_qu_parts" "$_qu_i" 2>/dev/null)" || _qu_it=""
		_qu_url="$(json_get "$_qu_it" presigned_url 2>/dev/null)" || _qu_url=""
		_qu_bs="$(json_get "$_qu_it" block_size 2>/dev/null)" || _qu_bs=""
		case "$_qu_bs" in ''|NOTFOUND|null) _qu_bs="$_qu_block" ;; esac
		case "$_qu_bs" in ''|*[!0-9]*)
			rm -f "$_qu_part"
			_ERROR="qqbot.upload: bad block_size for part $_qu_i"
			return 1 ;;
		esac
		case "$_qu_url" in ''|NOTFOUND|null)
			rm -f "$_qu_part"
			_ERROR="qqbot.upload: no presigned_url for part $_qu_i"
			return 1 ;;
		esac

		# dd counts fixed-size input blocks: part i starts at bs*skip
		dd if="$_qu_f" of="$_qu_part" bs="$_qu_bs" skip="$_qu_i" count=1 2>/dev/null || {
			rm -f "$_qu_part"
			_ERROR="qqbot.upload: dd failed at part $_qu_i"
			return 1
		}
		_qu_pmd5="$(_qqbot_md5 "$_qu_part")"

		_qu_try=1
		while :; do
			http_put_file "$_qu_url" "$_qu_part" "Content-Type: application/octet-stream" >/dev/null 2>&1
			_qu_put_rc=$?
			if [ $_qu_put_rc -eq 0 ]; then break; fi
			[ "$_qu_try" -ge "${QQBOT_UPLOAD_RETRY:-2}" ] && {
				rm -f "$_qu_part"
				_ERROR="qqbot.upload: PUT part $_qu_i failed (status ${_HTTP_STATUS:-none})"
				_qqbot_note_err "$_ERROR"
				return 1
			}
			_qu_try=$(( _qu_try + 1 ))
			sleep "${QQBOT_UPLOAD_RETRY_DELAY_OVERRIDE:-${QQBOT_UPLOAD_RETRY_DELAY:-1}}"
		done

		_qu_try=1
		while :; do
			qqbot_upload_part_finish "$1" "$2" "$_qu_id" "$_qu_i" "$_qu_bs" "$_qu_pmd5" >/dev/null && break
			[ "$_qu_try" -ge "${QQBOT_UPLOAD_RETRY:-2}" ] && {
				rm -f "$_qu_part"
				_ERROR="qqbot.upload: part_finish $_qu_i failed ($_ERROR)"
				_qqbot_note_err "$_ERROR"
				return 1
			}
			_qu_try=$(( _qu_try + 1 ))
			sleep "${QQBOT_UPLOAD_RETRY_DELAY_OVERRIDE:-${QQBOT_UPLOAD_RETRY_DELAY:-1}}"
		done

		_qu_i=$(( _qu_i + 1 ))
	done
	rm -f "$_qu_part"

	qqbot_upload_merge "$1" "$2" "$_qu_ty" "$_qu_n" "$_qu_id" "$_qu_srv"
}

# ---- media images (Markdown qqbot-media://) -----------------------------
# 限额：单图 ≤10MB，png/jpeg/gif/webp，单机器人 100 张，引用链接滑动 90 天有效。

# qqbot_media_image_prepare <file_name> <file_size> <content_type> <md5> <sha1>
qqbot_media_image_prepare() {
	if [ -z "${3:-}" ] || [ -z "${4:-}" ] || [ -z "${5:-}" ]; then
		_ERROR="qqbot.media.prepare: content_type, md5 and sha1 are required"
		return 1
	fi
	_qqbot_api POST "/v2/media-images/prepare" \
		"$(json_obj file_name "$1" file_size "$2" content_type "$3" md5 "$4" sha1 "$5")" \
		"qqbot.media.prepare"
}

# qqbot_media_image_complete <upload_id> <md5>
qqbot_media_image_complete() {
	_qqbot_api POST "/v2/media-images/complete" \
		"$(json_obj upload_id "$1" md5 "$2")" "qqbot.media.complete"
}

# qqbot_media_image_upload <path> [file_name]
# prepare → PUT presigned_url (Content-Type must equal the declared type) →
# complete. Sets:
#   _QQBOT_IMAGE_ID / _QQBOT_IMAGE_URL (qqbot-media://…) / _QQBOT_IMAGE_TTL /
#   _QQBOT_IMAGE_PREVIEW, and echoes the complete response body.
qqbot_media_image_upload() {
	_QQBOT_IMAGE_ID="" _QQBOT_IMAGE_URL="" _QQBOT_IMAGE_TTL="" _QQBOT_IMAGE_PREVIEW=""
	_qmi_f="$1" _qmi_n="${2:-}"
	[ -f "$_qmi_f" ] || { _ERROR="qqbot.media: no such file $_qmi_f"; return 1; }
	[ -n "$_qmi_n" ] || _qmi_n="${_qmi_f##*/}"
	_qmi_ct="$(_qqbot_image_ct "$_qmi_f")" || {
		_ERROR="qqbot.media: unsupported image type $_qmi_n (png/jpeg/gif/webp)"
		return 1
	}
	_qmi_sz="$(_qqbot_file_size "$_qmi_f")"
	if [ "${_qmi_sz:-0}" -gt 10485760 ]; then
		_ERROR="qqbot.media: image ${_qmi_sz}B exceeds the 10MB limit"
		return 1
	fi
	_qmi_md5="$(_qqbot_md5 "$_qmi_f")"
	_qmi_sha1="$(_qqbot_sha1 "$_qmi_f")"

	_qmi_prep="$(qqbot_media_image_prepare "$_qmi_n" "$_qmi_sz" "$_qmi_ct" "$_qmi_md5" "$_qmi_sha1")" || return 1
	_qmi_id="$(json_get "$_qmi_prep" upload_id 2>/dev/null)" || _qmi_id=""
	_qmi_url="$(json_get "$_qmi_prep" presigned_url 2>/dev/null)" || _qmi_url=""
	case "$_qmi_id" in ''|NOTFOUND|null)
		_ERROR="qqbot.media: no upload_id in response body=$(_qqbot_resp_digest "$_qmi_prep")"
		_qqbot_note_err "$_ERROR"; return 1 ;;
	esac
	case "$_qmi_url" in ''|NOTFOUND|null)
		_ERROR="qqbot.media: no presigned_url in response"
		return 1 ;;
	esac

	http_put_file "$_qmi_url" "$_qmi_f" "Content-Type: $_qmi_ct" >/dev/null 2>&1 || {
		_ERROR="qqbot.media: PUT failed (status ${_HTTP_STATUS:-none})"
		_qqbot_note_err "$_ERROR"
		return 1
	}
	# complete compares md5 against the COS ETag, which is the file's MD5
	_qmi_done="$(qqbot_media_image_complete "$_qmi_id" "$_qmi_md5")" || return 1
	_QQBOT_IMAGE_ID="$(json_get "$_qmi_done" image_id 2>/dev/null)" || _QQBOT_IMAGE_ID=""
	_QQBOT_IMAGE_URL="$(json_get "$_qmi_done" url 2>/dev/null)" || _QQBOT_IMAGE_URL=""
	_QQBOT_IMAGE_TTL="$(json_get "$_qmi_done" ttl 2>/dev/null)" || _QQBOT_IMAGE_TTL=""
	_QQBOT_IMAGE_PREVIEW="$(json_get "$_qmi_done" preview_url 2>/dev/null)" || _QQBOT_IMAGE_PREVIEW=""
	case "$_QQBOT_IMAGE_URL" in ''|NOTFOUND|null)
		_ERROR="qqbot.media: complete returned no url"
		return 1 ;;
	esac
	log_info "qqbot: media image uploaded id=$_QQBOT_IMAGE_ID size=$_qmi_sz"
	printf '%s' "$_qmi_done"
}

# qqbot_media_image_list [cursor]
qqbot_media_image_list() {
	_qqbot_api GET "/v2/media-images${1:+?cursor=$1}" "" "qqbot.media.list"
}

# qqbot_media_image_delete <image_id>
qqbot_media_image_delete() {
	_qqbot_api DELETE "/v2/media-images/$(qqbot_seg "$1")/delete" "{}" "qqbot.media.delete" >/dev/null
}

# qqbot_media_markdown <image_url> [alt] [width_px] [height_px]
# Build the ![]() form; width/height are optional and rendered as ` #800px`.
qqbot_media_markdown() {
	_qmm_alt="${2:-image}"
	_qmm_wh=""
	[ -n "${3:-}" ] && _qmm_wh=" #${3}px"
	[ -n "${4:-}" ] && _qmm_wh="$_qmm_wh #${4}px"
	printf '![%s%s](%s)' "$_qmm_alt" "$_qmm_wh" "$1"
}
