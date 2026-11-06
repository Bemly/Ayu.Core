# adapter/qqbot/group.sh — QQ group APIs (openid namespace)
#
# Covers: info, bot_state, members, blacklist, restrict_chat_setting,
# join_request_list / approval, batch_remove_members, chunked upload,
# and join_approval_strategy CRUD.
# All paths are /v2/groups/... — the guild-side group API is in guild.sh.

. "$_HB/adapter/qqbot/core.sh"

_qg() { printf '/v2/groups/%s' "$(qqbot_seg "$1")"; }

# ---- info / state -------------------------------------------------------

qqbot_group_info()        { _qqbot_api GET "$(_qg "$1")/info" "" "qqbot.group.info"; }
qqbot_group_bot_state()   { _qqbot_api GET "$(_qg "$1")/bot_state" "" "qqbot.group.bot_state"; }

# ---- members ------------------------------------------------------------

# qqbot_group_members <group_openid> [limit] [after]
qqbot_group_members() {
	_qqbot_api GET "$(_qg "$1")/members?limit=${2:-100}${3:+&after=$3}" "" "qqbot.group.members"
}

qqbot_group_member() {
	_qqbot_api GET "$(_qg "$1")/members/$(qqbot_seg "$2")" "" "qqbot.group.member"
}

# qqbot_group_batch_remove <group_openid> <members_json_array> [reject_add_request]
qqbot_group_batch_remove() {
	_qqbot_api POST "$(_qg "$1")/batch_remove_members" \
		"$(json_obj members "$2" reject_add_request "${3:-false}")" "qqbot.group.batch_remove"
}

# ---- blacklist ----------------------------------------------------------

qqbot_group_blacklist() {
	_qqbot_api GET "$(_qg "$1")/member_blacklist" "" "qqbot.group.blacklist"
}

# qqbot_group_blacklist_add <group_openid> <members_json_array> [ttl_seconds]
qqbot_group_blacklist_add() {
	_qqbot_api POST "$(_qg "$1")/member_blacklist" \
		"$(json_obj members "$2" ttl "${3:-0}")" "qqbot.group.blacklist_add"
}

qqbot_group_blacklist_del() {
	_qqbot_api DELETE "$(_qg "$1")/member_blacklist" \
		"$(json_obj members "$2")" "qqbot.group.blacklist_del"
}

# ---- restrict chat setting ---------------------------------------------

qqbot_group_restrict_setting() {
	_qqbot_api GET "$(_qg "$1")/restrict_chat_setting" "" "qqbot.group.restrict"
}

qqbot_group_restrict_set() {
	_qqbot_api POST "$(_qg "$1")/restrict_chat_setting" "$2" "qqbot.group.restrict_set"
}

# ---- join requests ------------------------------------------------------

# qqbot_group_join_requests <group_openid> [cursor] [limit]
qqbot_group_join_requests() {
	_qqbot_api GET "$(_qg "$1")/join_request_list?limit=${3:-20}${2:+&cursor=$2}" "" "qqbot.group.join_list"
}

# qqbot_group_join_approve <group_openid> <member_openid> <op> [reason]
# op: approve | reject | approve_and_ignore
qqbot_group_join_approve() {
	_qqbot_api POST "$(_qg "$1")/approval_join_request/$(qqbot_seg "$2")" \
		"$(json_obj op "$3" reason "${4:-}")" "qqbot.group.join_approve"
}

# ---- chunked file upload (group) ---------------------------------------

# qqbot_group_upload_prepare <group_id> <file_type> <file_size> <file_name> [md5] [sha1]
qqbot_group_upload_prepare() {
	_qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/upload_prepare" \
		"$(json_obj file_type "$2" file_size "$3" file_name "$4" md5 "${5:-}" sha1 "${6:-}")" \
		"qqbot.group.upload_prepare"
}

# qqbot_group_upload_finish <group_id> <upload_id> <part_list_json> [md5] [sha1]
qqbot_group_upload_finish() {
	_qqbot_api POST "/v2/groups/$(qqbot_seg "$1")/upload_part_finish" \
		"$(json_obj upload_id "$2" parts "$3" md5 "${4:-}" sha1 "${5:-}")" \
		"qqbot.group.upload_finish"
}

# ---- join approval strategy --------------------------------------------

qqbot_join_strategy_list() {
	_qqbot_api GET "/v2/groups/join_approval_strategy?group_openid=$(qqbot_seg "$1")" "" "qqbot.join_strategy.list"
}

qqbot_join_strategy_create() {
	_qqbot_api POST "/v2/groups/join_approval_strategy" "$2" "qqbot.join_strategy.create"
}

qqbot_join_strategy_get() {
	_qqbot_api GET "/v2/groups/join_approval_strategy/$(qqbot_seg "$1")" "" "qqbot.join_strategy.get"
}

qqbot_join_strategy_update() {
	_qqbot_api PATCH "/v2/groups/join_approval_strategy/$(qqbot_seg "$1")" "$2" "qqbot.join_strategy.update"
}

qqbot_join_strategy_delete() {
	_qqbot_api DELETE "/v2/groups/join_approval_strategy/$(qqbot_seg "$1")" "{}" "qqbot.join_strategy.delete" >/dev/null
}

qqbot_join_strategy_execute() {
	_qqbot_api POST "/v2/groups/join_approval_strategy/$(qqbot_seg "$1")/execute" "${2:-{}}" "qqbot.join_strategy.execute"
}

qqbot_join_strategy_whitelist() {
	_qqbot_api POST "/v2/groups/join_approval_strategy/$(qqbot_seg "$1")/whitelist_users" "$2" "qqbot.join_strategy.whitelist"
}
