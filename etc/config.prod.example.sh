# etc/config.prod.example.sh — template for the production profile
#
#   cp etc/config.prod.example.sh etc/config.prod.sh   # on the host only
#   chmod 600 etc/config.prod.sh
#
# etc/config.prod.sh is gitignored. Never commit it, never paste its contents
# into an issue, a log or a chat. Only the keys below are read by the code;
# existing production values in etc/config.sh stay untouched.

AYU_ENV="prod"

# ---- QQ Bot (official, bot.q.qq.com) ----
QQBOT_APP_ID=""
QQBOT_APP_SECRET=""
QQBOT_API_BASE="https://api.bot.qq.com"
# 1 = reject unsigned callbacks (fails closed if the Ed25519 helper is missing)
QQBOT_VERIFY_SIG="1"
# ---- QQ Bot self openid (command target check) ----
# The bot's own openid, as it appears in a message's leading <@...> mention.
# Set on a bot that receives the full group stream (GROUP_MESSAGE_CREATE):
# commands are only honoured when this exact openid is mentioned first.
QQBOT_BOT_OPENID="${QQBOT_BOT_OPENID:-}"

# ---- Webhook auth ----------------------------------------------------------
# Do NOT set WEBHOOK_SECRET here. This file is sourced AFTER etc/config.sh, so
# an empty assignment would silently wipe the live secret and open every
# webhook. The value stays where it has always been: etc/config.sh.
# Same rule for BOT_PORT / BOT_HOST: leave them out unless you really relocate
# the listener.

# ---- Bot server (optional overrides) ----
# BOT_PORT="${BOT_PORT:-6160}"
# BOT_HOST="${BOT_HOST:-0.0.0.0}"
