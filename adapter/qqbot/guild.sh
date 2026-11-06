# adapter/qqbot/guild.sh — QQ guild (channel) APIs
#
# The guild surface still uses the older /guilds, /channels, /users/@me paths.
# Only the subset the bot actually needs is wrapped; arbitrary calls can go
# through qqbot_guild_raw.

. "$_HB/adapter/qqbot/core.sh"

# ---- bot identity -------------------------------------------------------

qqbot_me()        { _qqbot_api GET "/users/@me" "" "qqbot.me"; }
qqbot_my_guilds() { _qqbot_api GET "/users/@me/guilds" "" "qqbot.guilds"; }

# ---- guild / channel ----------------------------------------------------

qqbot_guild_get()      { _qqbot_api GET "/guilds/$(qqbot_seg "$1")" "" "qqbot.guild.get"; }
qqbot_guild_channels() { _qqbot_api GET "/guilds/$(qqbot_seg "$1")/channels" "" "qqbot.guild.channels"; }

# qqbot_channel_create <guild_id> <json_body>
qqbot_channel_create() { _qqbot_api POST "/guilds/$(qqbot_seg "$1")/channels" "$2" "qqbot.channel.create"; }

qqbot_channel_get()    { _qqbot_api GET "/channels/$(qqbot_seg "$1")" "" "qqbot.channel.get"; }
qqbot_channel_update() { _qqbot_api PATCH "/channels/$(qqbot_seg "$1")" "$2" "qqbot.channel.update"; }
qqbot_channel_delete() { _qqbot_api DELETE "/channels/$(qqbot_seg "$1")" "{}" "qqbot.channel.delete" >/dev/null; }

# ---- interaction ack ----------------------------------------------------

# qqbot_interaction_ack <interaction_id> [code]  — code 0 = success
qqbot_interaction_ack() {
	_qqbot_api PUT "/interactions/$(qqbot_seg "$1")" \
		"$(json_obj code "${2:-0}")" "qqbot.interaction.ack" >/dev/null
}

# ---- escape hatch -------------------------------------------------------

# qqbot_raw <METHOD> <path> [body] — path is appended to QQBOT_API_BASE as-is
qqbot_raw() {
	_qr_body="${3:-}"
	[ -n "$_qr_body" ] || _qr_body="{}"
	_qqbot_api "$1" "$2" "$_qr_body" "qqbot.raw"
}
