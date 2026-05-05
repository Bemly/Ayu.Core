# Discord Webhook API

. "$_HB/adapter/discord/core.sh"

dc_webhook_execute() {
    _url="https://discord.com/api/webhooks/$1/$2"
    _body="$(json_obj "content" "$3")"
    [ -n "${4:-}" ] && _body="$(printf '%s' "$_body" | sed 's/}$/,"username":"'"$4"'"/}')"
    http_post "$_url" "$_body" "Content-Type:application/json" || {
        _ERROR="dc.webhook_execute: $_ERROR"
        return 1
    }
}

dc_webhook_get()              { _dc_get "/webhooks/$1"; }
dc_webhook_token_get()        { _dc_get "/webhooks/$1/$2"; }
dc_webhook_modify()           { _dc_api "PATCH" "/webhooks/$1" "$2"; }
dc_webhook_token_modify()     { _dc_api "PATCH" "/webhooks/$1/$2" "$3"; }
dc_webhook_delete()           { _dc_void "DELETE" "/webhooks/$1"; }
dc_webhook_token_delete()     { _dc_void "DELETE" "/webhooks/$1/$2"; }
dc_webhook_create()           { _dc_api "POST" "/channels/$1/webhooks" "$2"; }
dc_channel_webhook_list()     { _dc_get "/channels/$1/webhooks"; }
dc_guild_webhook_list()       { _dc_get "/guilds/$1/webhooks"; }
dc_webhook_message_edit()     { _dc_api "PATCH" "/webhooks/$1/$2/messages/$3" "$4"; }
dc_webhook_message_delete()   { _dc_void "DELETE" "/webhooks/$1/$2/messages/$3"; }

# Webhook event handler for incoming Discord interactions
# Note: Discord message events require Gateway (WebSocket), not supported in pure shell.
dc_webhook_handler() {
	_body="$1"

	# Discord sends PING (type=1) for endpoint verification
	_type="$(json_get "$_body" type 2>/dev/null)" || _type=""
	if [ "$_type" = "1" ]; then
		log_info "dc_webhook: PING verification"
		return 0
	fi

	log_debug "dc_webhook: event type=$_type"
	return 0
}
