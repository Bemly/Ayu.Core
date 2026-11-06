# etc/config.dev.sh — development / test profile
#
# Committed to the repo: contains NO live credentials. Anything sensitive is
# expected from the environment (e.g. `export QQBOT_APP_SECRET=...`) when you
# deliberately point the dev profile at the real platform.
#
# Activate: AYU_ENV=dev (also the default when etc/config.prod.sh is absent).

AYU_ENV="dev"

# ---- QQ Bot (official) ----
# Leave the secret empty unless you are testing against the real API; the
# test suite only exercises body builders and signature vectors.
QQBOT_APP_ID="${QQBOT_APP_ID:-}"
QQBOT_APP_SECRET="${QQBOT_APP_SECRET:-}"
QQBOT_API_BASE="${QQBOT_API_BASE:-https://api.bot.qq.com}"
# dev runs with the shared-secret check only (no Ed25519 helper needed).
# Assigned unconditionally: the template already set it to "auto".
QQBOT_VERIFY_SIG="0"

# ---- Logging ----
_LOG_LEVEL="${_LOG_LEVEL:-0}"

# NOTE: WEBHOOK_SECRET / BOT_PORT are deliberately left untouched here so the
# dev profile keeps the same defaults as the template (the test suite reads the
# effective value and must not depend on a particular secret).
