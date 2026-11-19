# Discord Webhook API

. "$_HB/adapter/discord/core.sh"

dc_webhook_execute() {
	_url="https://discord.com/api/webhooks/$1/$2"
	_body="$(json_obj "content" "$3")"
	[ -n "${4:-}" ] && _body="$(printf '%s' "$_body" | sed 's/}$/,"username":"'"$4"'"/}')"
	http_post "$_url" "$_body" "$_CT_JSON" "${_DC_AYU_AUTH:-}" || {
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
#
# Interaction responses are written to stdout by this function: router.sh emits
# the Content-Type header and exits, so whatever is printed here is the body.
# The ACK for a component interaction goes out BEFORE the relay POST, because
# Discord closes the interaction after 3 seconds.
dc_webhook_handler() {
	_body="$1"

	# Discord sends PING (type=1) for endpoint verification
	_type="$(json_get "$_body" type 2>/dev/null)" || _type=""
	if [ "$_type" = "1" ]; then
		log_info "dc_webhook: PING verification"
		printf '{"type":1}'
		return 0
	fi

	# type=3 MESSAGE_COMPONENT — a button/select click on a message we sent.
	if [ "$_type" = "3" ]; then
		_dwh_data="$(json_get "$_body" data 2>/dev/null)" || _dwh_data=""
		_dwh_cid="$(json_get "$_dwh_data" custom_id 2>/dev/null)" || _dwh_cid=""
		case "$_dwh_cid" in NOTFOUND|null) _dwh_cid="" ;; esac
		# ACK first: {"type":6} = DEFERRED_UPDATE_MESSAGE (no visible change).
		printf '{"type":6}'
		[ -n "$_dwh_cid" ] || return 0
		log_info "dc_webhook: component custom_id=$_dwh_cid"
		dispatch "discord" "component" "" "$_dwh_cid" "$_body"
		return 0
	fi

	log_debug "dc_webhook: event type=$_type"
	printf '{"status":"ok"}'
	return 0
}
