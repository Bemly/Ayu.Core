# Discord Message API

. "$_HB/adapter/discord/core.sh"

dc_message_list()          { _dc_get "/channels/$1/messages"; }
dc_message_get()           { _dc_get "/channels/$1/messages/$2"; }
dc_message_create()        { _dc_api "POST" "/channels/$1/messages" "$2"; }
dc_message_edit()          { _dc_api "PATCH" "/channels/$1/messages/$2" "$3"; }
dc_message_delete()        { _dc_void "DELETE" "/channels/$1/messages/$2"; }
dc_message_bulk_delete()   { _dc_api "POST" "/channels/$1/messages/bulk-delete" "$2"; }
dc_message_crosspost()     { _dc_api "POST" "/channels/$1/messages/$2/crosspost" "{}"; }
dc_pin_list()              { _dc_get "/channels/$1/pins"; }
dc_pin_add()               { _dc_void "PUT" "/channels/$1/pins/$2"; }
dc_pin_remove()            { _dc_void "DELETE" "/channels/$1/pins/$2"; }
dc_reaction_add()          { _dc_void "PUT" "/channels/$1/messages/$2/reactions/$3/@me"; }
dc_reaction_delete()       { _dc_void "DELETE" "/channels/$1/messages/$2/reactions/$3/@me"; }
