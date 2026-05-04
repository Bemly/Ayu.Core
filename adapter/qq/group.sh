# QQ Group API

. "$_HB/adapter/qq/system.sh"  # for _qq_call, _qq_api

qq_group_get_list()          { _qq_api "get_group_list" "$(json_obj "no_cache" "${1:-false}")" "qq.group_list"; }
qq_group_get_info()          { _qq_api "get_group_info" "$(json_obj "group_id" "$1" "no_cache" "${2:-false}")" "qq.group_info"; }
qq_group_get_member_list()   { _qq_api "get_group_member_list" "$(json_obj "group_id" "$1" "no_cache" "${2:-false}")" "qq.member_list"; }
qq_group_get_member_info()   { _qq_api "get_group_member_info" "$(json_obj "group_id" "$1" "user_id" "$2" "no_cache" "${3:-false}")" "qq.member_info"; }
qq_group_set_name()          { _qq_call "set_group_name" "$(json_obj "group_id" "$1" "new_group_name" "$2")" >/dev/null; }
qq_group_set_member_card()   { _qq_call "set_group_member_card" "$(json_obj "group_id" "$1" "user_id" "$2" "card" "$3")" >/dev/null; }
qq_group_send_nudge()        { _qq_call "send_group_nudge" "$(json_obj "group_id" "$1" "user_id" "$2")" >/dev/null; }
qq_group_quit()                  { _qq_call "quit_group" "$(json_obj "group_id" "$1")" >/dev/null; }
qq_group_set_member_special_title() { _qq_call "set_group_member_special_title" "$(json_obj "group_id" "$1" "user_id" "$2" "special_title" "$3")" >/dev/null; }
qq_group_get_notifications()    { _qq_api "get_group_notifications" "$(json_obj "start_notification_seq" "${1:-0}" "is_filtered" "${2:-false}" "limit" "${3:-20}")" "qq.notifications"; }
qq_group_send_reaction()        { _qq_call "send_group_message_reaction" "$(json_obj "group_id" "$1" "message_seq" "$2" "reaction" "\"$3\"" "is_add" "${4:-true}" "reaction_type" "${5:-face}")" >/dev/null; }
