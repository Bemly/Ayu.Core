# Ayu.Core config — tokens, endpoints, settings
# Source after core.sh

# ---- QQ (Milky / LLOneBot) ----
QQ_HOST="${QQ_HOST:-host.docker.internal}"
QQ_PORT="${QQ_PORT:-616}"
QQ_PREFIX="${QQ_PREFIX:-/}"
QQ_TOKEN="${QQ_TOKEN:-}"

# QQ API base URL
QQ_API_BASE="http://${QQ_HOST}:${QQ_PORT}${QQ_PREFIX}api"

# ---- QQ Bot (Tencent official OpenAPI v2) ----
# Independent from QQ (Milky) above: AppID/AppSecret auth, HTTPS + webhook callback.
# See adapter/qqbot/README.md. Secrets stay in env / config.nas.sh, never in the repo.

# ---- Telegram ----
TG_TOKEN="${TG_TOKEN:-}"
TG_API_HOST="${TG_API_HOST:-api.telegram.org}"
TG_API_SECRET="${TG_API_SECRET:-}"
TG_API_BASE="https://${TG_API_HOST}/bot${TG_TOKEN}"

# ---- Bot self-IDs (loop prevention) ----
QQ_BOT_ID="${QQ_BOT_ID:-3156037162}"
# ---- QQ Bot self openid (command target check) ----
# The bot's own openid, as it appears in a message's leading <@...> mention.
# Set on a bot that receives the full group stream (GROUP_MESSAGE_CREATE):
# commands are only honoured when this exact openid is mentioned first.
QQBOT_BOT_OPENID="${QQBOT_BOT_OPENID:-}"
TG_BOT_ID="${TG_BOT_ID:-8723729335}"

# ---- Discord ----
DC_TOKEN="${DC_TOKEN:-}"
DC_API_BASE="https://discord.com/api/v10"
DC_BOT_ID="${DC_BOT_ID:-}"
# Proxy for cdn.discordapp.com (set on NAS if blocked, e.g. dchook.bemly.moe/cdn)
DC_CDN_PROXY="${DC_CDN_PROXY:-}"

# ---- QQ Bot (official, bot.q.qq.com) ----
# Webhook mode only (no WebSocket gateway). Keep empty in the repo: the
# production values live in etc/config.prod.sh, which is gitignored.
QQBOT_APP_ID="${QQBOT_APP_ID:-}"
QQBOT_APP_SECRET="${QQBOT_APP_SECRET:-}"
QQBOT_API_BASE="${QQBOT_API_BASE:-https://api.bot.qq.com}"
# inbound Ed25519 check: auto (when helper+secret exist) | 1 | 0
QQBOT_VERIFY_SIG="${QQBOT_VERIFY_SIG:-auto}"
# Optional URL-safe token accepted in place of ?token=<WEBHOOK_SECRET>.
# Needed because WEBHOOK_SECRET may contain '#' / ';' / '<', which truncate the
# callback URL before it ever reaches us. Keep empty in the repo.
QQBOT_WEBHOOK_TOKEN="${QQBOT_WEBHOOK_TOKEN:-}"
# Group admins allowed to bind nicknames to openids with `@bot @someone 昵称`.
# Space separated; full openid or a ≥7-char prefix. Member openids are
# per-group, so an admin id only carries over inside the same group.
# Space separated openids (>=7-char prefix accepted) allowed to bind nicknames
# and read history. Deliberately empty in the committed template: the real
# admin list belongs to etc/config.prod.sh, not to code.
QQBOT_ADMINS="${QQBOT_ADMINS:-}"

# ---- Bot server ----
BOT_PORT="${BOT_PORT:-6160}"
BOT_HOST="${BOT_HOST:-0.0.0.0}"

# Webhook auth: if set, require ?token=<secret> in webhook URL
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"

# ---- Logging ----
_LOG_LEVEL="${_LOG_LEVEL:-1}"    # 0=trace, 1=info, 2=warn, 3=err
_LOG_DIR="${_LOG_DIR:-$_HB/var/log}"

# ---- State ----
_STATE_DIR="${_STATE_DIR:-$_HB/var/state}"

# ---- Environment overlay ----
# This file only holds template defaults (all secrets empty) and is committed.
# Real values live in etc/config.<env>.sh:
#   dev  — committed, fake/mock values, used by test/run.sh and local runs
#   prod — live credentials, gitignored, never leaves the host
# AYU_ENV may be exported; otherwise prod is inferred from the presence of
# etc/config.prod.sh.
if [ -z "${AYU_ENV:-}" ]; then
	if [ -f "$_HB/etc/config.prod.sh" ]; then AYU_ENV="prod"; else AYU_ENV="dev"; fi
fi
if [ -f "$_HB/etc/config.${AYU_ENV}.sh" ]; then
	. "$_HB/etc/config.${AYU_ENV}.sh"
fi
