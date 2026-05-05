# adapter/discord/webhook.sh — Discord webhook event handler
# Processes incoming Discord Interactions (slash commands, etc.)
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
