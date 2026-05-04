# Telegram Bot API — getMe, getUpdates, webhook management

. "$_HB/adapter/telegram/core.sh"

tg_getMe()           { _tg_api "getMe" "{}" "tg.getMe"; }
tg_getUpdates()      { _tg_api "getUpdates" "$(json_obj "offset" "${1:-0}" "limit" "${2:-100}")" "tg.getUpdates"; }
tg_setWebhook()      { _tg_api "setWebhook" "$(json_obj "url" "$1" "allowed_updates" "${2:-[\"message\",\"edited_message\",\"channel_post\",\"callback_query\",\"message_reaction\"]}")" "tg.setWebhook"; }
tg_deleteWebhook()   { _tg_api "deleteWebhook" "{}" "tg.deleteWebhook"; }
tg_getWebhookInfo()  { _tg_api "getWebhookInfo" "{}" "tg.webhookInfo"; }
tg_logOut()          { _tg_api "logOut" "{}" "tg.logOut"; }
tg_close()           { _tg_api "close" "{}" "tg.close"; }
