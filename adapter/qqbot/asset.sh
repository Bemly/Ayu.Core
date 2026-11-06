# adapter/qqbot/asset.sh — media image / menu / panel / url-link APIs
#
# These are management-plane calls (upload images for messages, maintain the
# command menu, manage panels). They share the same access_token as messaging.

. "$_HB/adapter/qqbot/core.sh"

# ---- media images -------------------------------------------------------

# qqbot_media_image_prepare <file_type> <file_size> [file_name] [md5] [sha1]
qqbot_media_image_prepare() {
	_qqbot_api POST "/v2/media-images/prepare" \
		"$(json_obj file_type "$1" file_size "$2" file_name "${3:-}" md5 "${4:-}" sha1 "${5:-}")" \
		"qqbot.media.prepare"
}

qqbot_media_image_complete() {
	_qqbot_api POST "/v2/media-images/complete" "$1" "qqbot.media.complete"
}

# qqbot_media_image_list [cursor]
qqbot_media_image_list() {
	_qqbot_api GET "/v2/media-images${1:+?cursor=$1}" "" "qqbot.media.list"
}

qqbot_media_image_delete() {
	_qqbot_api DELETE "/v2/media-images/$(qqbot_seg "$1")/delete" "{}" "qqbot.media.delete" >/dev/null
}

# ---- url link -----------------------------------------------------------

# qqbot_generate_url_link <json_body>  — body: {url, ...} per OpenAPI spec
qqbot_generate_url_link() {
	_qqbot_api POST "/v2/generate_url_link" "$1" "qqbot.url_link"
}

# ---- command menu -------------------------------------------------------

qqbot_menu_get() { _qqbot_api GET "/v2/menu" "" "qqbot.menu.get"; }
qqbot_menu_put() { _qqbot_api PUT "/v2/menu" "$1" "qqbot.menu.put"; }

# ---- panels -------------------------------------------------------------

qqbot_panel_list()   { _qqbot_api GET "/v2/panels" "" "qqbot.panel.list"; }
qqbot_panel_get()    { _qqbot_api GET "/v2/panels/$(qqbot_seg "$1")" "" "qqbot.panel.get"; }
qqbot_panel_create() { _qqbot_api POST "/v2/panels" "$1" "qqbot.panel.create"; }

# qqbot_panel_update <panel_id> <json_body>
qqbot_panel_update() { _qqbot_api PUT "/v2/panels/$(qqbot_seg "$1")" "$2" "qqbot.panel.update"; }
qqbot_panel_delete() { _qqbot_api DELETE "/v2/panels/$(qqbot_seg "$1")" "{}" "qqbot.panel.delete" >/dev/null; }

# qqbot_panel_target <panel_id> <json_body>  — set the panel's target scope
qqbot_panel_target() { _qqbot_api PUT "/v2/panels/$(qqbot_seg "$1")/target" "$2" "qqbot.panel.target"; }

# ---- c2c chunked upload -------------------------------------------------

# qqbot_user_upload_prepare <user_id> <file_type> <file_size> <file_name> [md5] [sha1]
qqbot_user_upload_prepare() {
	_qqbot_api POST "/v2/users/$(qqbot_seg "$1")/upload_prepare" \
		"$(json_obj file_type "$2" file_size "$3" file_name "$4" md5 "${5:-}" sha1 "${6:-}")" \
		"qqbot.user.upload_prepare"
}

qqbot_user_upload_finish() {
	_qqbot_api POST "/v2/users/$(qqbot_seg "$1")/upload_part_finish" \
		"$(json_obj upload_id "$2" parts "$3" md5 "${4:-}" sha1 "${5:-}")" \
		"qqbot.user.upload_finish"
}
