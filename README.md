![# Ayu.Core](https://socialify.git.ci/Bemly/Ayu.Core/image?description=1&font=Raleway&language=1&logo=https%3A%2F%2Fraw.githubusercontent.com%2FBemly%2FAyu.Core%2Frefs%2Fheads%2Fmain%2Fwebui%2Flogo.jpg&name=1&owner=1&pattern=Diagonal+Stripes&theme=Dark)

[![test](https://github.com/Bemly/Ayu.Core/actions/workflows/test.yml/badge.svg)](https://github.com/Bemly/Ayu.Core/actions/workflows/test.yml)

Pure shell SNS Bot framework. Runs in busybox:musl container, hush + httpd CGI + raw TLS transport + [hush-json](https://github.com/Bemly/hush-json) + [hush-ed25519](https://github.com/Bemly/hush-ed25519).

> [中文文档](README.zh.md)

## Adapter Coverage

| Platform | Endpoints | Functions | Reference |
|----------|-----------|-----------|-----------|
| QQ (Milky / LLOneBot) | 29/29 | 39 | [adapter/qq/README.md](adapter/qq/README.md) |
| QQ Bot (Official OpenAPI v2, webhook) | 46 HTTP APIs / 22 events (20 handled) | 125 | [adapter/qqbot/README.md](adapter/qqbot/README.md) |
| Telegram Bot API | 169/169 | 175 | [adapter/telegram/README.md](adapter/telegram/README.md) |
| Discord REST API v10 | 185 bot API | 143 | [adapter/discord/README.md](adapter/discord/README.md) |

Function counts are `grep -cE '^[a-z_]+\(\)'` over each adapter directory. Full protocol references live in
[adapter/qq/README.md](adapter/qq/README.md) (370 lines, Milky API) and
[adapter/qqbot/README.md](adapter/qqbot/README.md) (10 chapters, official OpenAPI v2 + webhook).

### QQ Bot at a glance

| Item | Value |
|------|-------|
| Callback path | `/cgi-bin/router.sh/qqbot` (exact segment — `/qqbotxxx` is rejected, `/qq` stays separate) |
| Transport | HTTPS API + webhook callback (the WebSocket gateway is **not** implemented) |
| Outbound auth | `Authorization: QQBot <access_token>` — `POST /app/getAppAccessToken`, cached and refreshed ahead of expiry |
| Inbound auth | `?token=<WEBHOOK_SECRET>` (or `QQBOT_WEBHOOK_TOKEN`) **plus** Ed25519 `X-Signature-Ed25519` / `X-Signature-Timestamp` |
| URL verification | `op=13` → echo `plain_token` + `signature` |
| Event ACK | `op=0` → `{"op":12,"d":{}}` (platform retries unless ACKed) |
| ID space | `openid` / `group_openid` only — never QQ numbers |
| Code | 9 files / 125 functions under `adapter/qqbot/` |
| Tests | 138 of the 486 tests exercise this adapter |

`QQBOT_VERIFY_SIG` selects the verification mode: `auto` (on when the secret and the Ed25519 helper are present),
`1` (fail closed — unsigned callbacks are rejected), `0` (off, not recommended).

## Architecture

```
Request flow:
  Platform → webhook → httpd CGI → router.sh → adapter → dispatch.sh → handler → adapter → nc+ssl_client → Platform

Ayu.Core/
├── cgi-bin/                # CGI scripts (busybox httpd hardcodes /cgi-bin/)
│   ├── start.sh            # Launch httpd + crond
│   └── router.sh           # CGI entry (platform routing + token auth)
├── lib/
│   ├── core.sh             # _ERROR chain, die(), hush-json + hush-url bootstrap
│   ├── http.sh             # HTTP/HTTPS via nc + ssl_client (GET/POST, retry, chunked decode)
│   ├── dispatch.sh         # Message routing + plugin interface (etc/rules)
│   ├── log.sh              # Leveled logging (debug/info/warn/err)
│   └── url.sh              # url_encode/decode + utf8_decode (\uXXXX→UTF-8)
├── adapter/                # Platform adapters
│   ├── qq/                 # QQ (Milky) — 7 files, 39 functions, 15 segment types, 8 event types
│   ├── qqbot/              # QQ Bot official OpenAPI v2 — 9 files, 125 functions, webhook + Ed25519
│   ├── telegram/           # Telegram — 17 files, 175 functions, 20 Update types, 18 content types
│   └── discord/            # Discord — 19 files, 143 functions (REST + webhook)
├── plugin/                 # Business logic
│   └── sync/               # Cross-platform sync (QQ/QQBot/TG/DC) + dc-sync.sh (crond entry)
├── index.xml               # Entry document — points at the XML dashboard
├── webui/                  # README cover logo only; the panel draws itself in CSS
├── etc/                    # config, rules, crontab, sync.conf, README
├── hush-json/              # submodule — JSON in POSIX sh
├── hush-ed25519/           # submodule — Ed25519 sign/verify in shell + busybox awk
└── test/                   # 486 tests, 0 failures (mock_http, no API keys)
```

## Quick Start

```sh
# Build
docker build -t ayu-core .

# Run
docker run -d -p 6160:6160 --name ayu ayu-core

# QQ webhook
curl -X POST http://localhost:6160/cgi-bin/router.sh/qq \
  -H 'Content-Type: application/json' \
  -d '{"event_type":"message_receive","data":{"sender_id":111,"message_scene":"friend","segments":[{"type":"text","data":{"text":"/ping"}}]}}'
# → {"status":"ok"}

# Telegram webhook
curl -X POST http://localhost:6160/cgi-bin/router.sh/telegram \
  -H 'Content-Type: application/json' \
  -d '{"update_id":1,"message":{"from":{"id":111},"chat":{"id":222},"text":"/ping"}}'
# → {"status":"ok"}

# QQ Bot webhook — URL verification (op=13)
curl -X POST 'http://localhost:6160/cgi-bin/router.sh/qqbot?token=<WEBHOOK_SECRET>' \
  -H 'Content-Type: application/json' \
  -d '{"op":13,"d":{"plain_token":"Arq0D5A61EgUu4OxUvOp","event_ts":"1725442341"}}'
# → {"plain_token":"...","signature":"..."}

# QQ Bot webhook — event ACK (op=0, requires a valid Ed25519 signature)
curl -X POST 'http://localhost:6160/cgi-bin/router.sh/qqbot?token=<WEBHOOK_SECRET>' \
  -H 'Content-Type: application/json' \
  -H 'X-Signature-Ed25519: <sig>' -H 'X-Signature-Timestamp: <ts>' \
  -d '{"op":0,"t":"GROUP_AT_MESSAGE_CREATE","id":"EVENT_ID","d":{}}'
# → {"op":12,"d":{}}      (bad signature → 401, bad token → 403)
```

## Configuration

```sh
# etc/config.sh — all values can be overridden via environment variables
QQ_HOST="host.docker.internal"   # bridge: host.docker.internal, host: 127.0.0.1
QQ_PORT="616"
QQ_TOKEN=""                      # set via env or the prod overlay

TG_TOKEN=""                      # Bot token from @BotFather
TG_API_HOST="api.telegram.org"   # use a CF Worker for network accessibility
TG_API_SECRET=""                 # X-Ayu-Token header for edge authentication
TG_BOT_ID=""                     # bot's own id — skip self, avoid loops

DC_TOKEN=""
DC_BOT_ID=""                     # skip the bot's own messages (loop prevention)
DC_CDN_PROXY=""                  # proxy for cdn.discordapp.com when blocked

# --- QQ Bot (official OpenAPI v2, webhook only) ---
QQBOT_APP_ID=""                  # AppID from q.qq.com
QQBOT_APP_SECRET=""              # AppSecret — also the Ed25519 seed for callbacks
QQBOT_API_BASE="https://api.bot.qq.com"
QQBOT_VERIFY_SIG="auto"          # auto | 1 (fail closed) | 0 (off)
QQBOT_WEBHOOK_TOKEN=""           # URL-safe token; use when WEBHOOK_SECRET contains # < ;
QQBOT_BOT_OPENID=""              # bot's own openid — full-stream commands must @ it
QQBOT_ADMINS=""                  # openids allowed to run `历史` (space separated, >=7-char prefix)

BOT_PORT="6160"
WEBHOOK_SECRET=""                # if set, require ?token=<secret> in webhook URL
_LOG_LEVEL="1"                   # 0=trace, 1=info, 2=warn, 3=err
```

> Never commit secrets. The repository ships `etc/config.sh` with empty defaults only.
> Production values live in `etc/config.prod.sh` (gitignored, sourced when `AYU_ENV=prod`);
> start from `etc/config.prod.example.sh`. `etc/config.dev.sh` / `etc/config.local.sh` cover
> the other profiles, and `etc/config.prod.sh` wins over `etc/config.sh` key by key.

QQ Bot keys in detail:

| Key | Default | Meaning |
|-----|---------|---------|
| `QQBOT_APP_ID` | empty | AppID from the QQ open platform |
| `QQBOT_APP_SECRET` | empty | AppSecret; also the Ed25519 seed for callback verification |
| `QQBOT_API_BASE` | `https://api.bot.qq.com` | API root (override for a proxy) |
| `QQBOT_VERIFY_SIG` | `auto` | `auto` / `1` fail closed / `0` off |
| `QQBOT_WEBHOOK_TOKEN` | empty | URL-safe token for `/qqbot`, overrides `WEBHOOK_SECRET` |
| `QQBOT_BOT_OPENID` | empty | bot's own openid; full-stream commands must @ it |
| `QQBOT_ADMINS` | one id in `etc/config.sh` | openids allowed to run `历史` (space separated, `>=7`-char prefix ok) |
| `QQBOT_HIST_KEEP` | `50` | history lines kept per conversation |
| `QQBOT_HIST_SHOW` | `5` | lines returned by `@bot 历史` |

## Platform APIs

```sh
. ./lib/core.sh && . ./etc/config.sh

# --- QQ ---
. ./adapter/qq/message.sh
qq_message_send_group "123456" "$(qq_text_segments 'hello')"

# --- Telegram ---
. ./adapter/telegram/message.sh
tg_sendMessage "222" "hello world" "HTML"

# --- Discord ---
. ./adapter/discord/message.sh
dc_message_create "ch1" '{"content":"hello"}'

# --- QQ Bot (official) ---
. ./adapter/qqbot/message.sh
qqbot_message_send_group "<group_openid>" "$(qqbot_body_text 'hello')"
qqbot_message_send_c2c   "<user_openid>"  "$(qqbot_body_text 'hello')"
qqbot_message_recall_group "<group_openid>" "<msg_id>"
```

## Message Dispatch

`etc/rules` — one rule per line: `<pattern>|<handler_file>|<handler_func>`

```
qqbot:/ping|qqbot/handler.sh|qqbot_handler_ping
qqbot:/echo|qqbot/handler.sh|qqbot_handler_echo
qqbot:/info|qqbot/handler.sh|qqbot_handler_info
qqbot:/recall|qqbot/handler.sh|qqbot_handler_recall
/ping|qq/handler.sh|handler_ping
/echo|qq/handler.sh|handler_echo
/info|qq/handler.sh|handler_info
*|../plugin/sync/handler.sh|sync_handler
```

Rules are matched first-to-last. Commands match first; the `*` fallback forwards to cross-platform sync.

A rule may carry an optional `<platform>:` prefix — `qq:`, `qqbot:`, `telegram:`, `discord:` — and then only fires
for that platform. **A rule without a prefix matches every platform** (legacy behaviour), which is why the old
`/ping|qq/handler.sh|handler_ping` style also fires on qqbot events. Prefix platform-specific commands:

| Rule | Platforms | Effect |
|------|-----------|--------|
| `qqbot:/ping` | qqbot only | official-bot built-in command |
| `qq:/ping` | QQ (Milky) only | Milky adapter command |
| `/ping` | all four | fires everywhere — avoid for platform-specific handlers |

## Plugin System

See [etc/README.md](etc/README.md) for the framework plugin API — handler signatures, registration files, available adapter functions.

### Registration files:

| File | Purpose | Format |
|------|---------|--------|
| `etc/rules` | Message routing (real-time) | `<pattern>\|<script>\|<func>` |
| `etc/crontab` | Scheduled tasks (crond) | `<cron expr>\|<script>\|<func>` |
| `etc/sync.conf` | Cross-platform sync mapping | `<src>=<tgt>` |

## Cross-Platform Sync

See [plugin/sync/README.md](plugin/sync/README.md) for full documentation.

### Discord Sync

| Direction | Method | Media | Trigger |
|-----------|--------|-------|---------|
| QQ → DC | Real-time | Text, image, file, voice, video | Webhook (instant) |
| TG → DC | Real-time | Text, image, file, voice, video, sticker, GIF | Webhook (instant) |
| DC → QQ | Daily batch | Text only (media planned) | Cron → `dc-sync.sh` |
| DC → TG | Daily batch | Text only (media planned) | Cron → `dc-sync.sh` |

**Why DC inbound is batch-only**: Discord message events require Gateway (WebSocket), which is not feasible in pure shell. Instead, `cgi-bin/dc-sync.sh` fetches messages via REST API (`GET /channels/{id}/messages`), filters by today's date, and forwards to configured targets.

**Triggering DC sync**: container's built-in `crond` runs `dc_batch_run()` daily at UTC midnight via `etc/crontab`:
```
0 0 * * *|../plugin/sync/dc-sync.sh|dc_batch_run  # DC daily message sync
```
Add entries to `etc/crontab` to schedule other tasks. See `etc/README.md` for the framework plugin API.

**sync.conf format:**
```
qq/group/1081590429=discord/ch123456           # QQ group → DC channel
telegram/-100111=discord/ch123456              # TG group → DC channel
discord/ch123456=qq/group/1081590429           # DC channel → QQ (daily batch)
discord/ch123456=telegram/-100111              # DC channel → TG (daily batch)
```

**Loop prevention**: `👾` emoji prefix + bot sender ID check (`DC_BOT_ID` env var). DC→QQ/TG forwarding skips messages authored by the bot itself.

### QQ Bot (official) Sync

| Direction | Method | Media | Trigger |
|-----------|--------|-------|---------|
| qqbot → TG | Real-time | Text, image, file, voice (WAV transcode preferred), video | Webhook |
| qqbot → DC | Real-time | Text, image, file, voice, video | Webhook |
| TG → qqbot | Real-time | Text, image, file, voice, video | `*` rule |
| DC → qqbot | Daily batch | Text only | Cron → `dc-sync.sh` |
| qqbot recall → TG/DC | Real-time | rev-map lookup | Webhook |

Official callbacks carry media only as `attachments` (`url` + `content_type`, no local path, no segments), so each
item is downloaded once and re-uploaded through the existing multipart helpers. The relay is best-effort: a failed
attachment is logged and the text message still goes out.

Senders are rendered as `🅠 nick(qq#ABC1234)`. Events do define `author.username`, but the platform leaves it empty
for most bots — only a per-bot `member_openid` is guaranteed — so a name appears only when the platform sends one
(it is cached in `var/state/qqbot-nick-auto/<group_openid>` and reused on later messages). There is no way to set a
name by hand (see below).

`etc/sync.conf` targets and sources:

```
qqbot/group/<group_openid>=telegram/-100111      # qqbot group → TG
qqbot/group/<group_openid>=discord/ch123456      # qqbot group → DC
telegram/-100111=qqbot/group/<group_openid>      # TG → qqbot group
telegram/-100111=qqbot/private/<user_openid>     # TG → qqbot C2C
discord/ch123456=qqbot/channel/<channel_id>      # DC → qqbot channel
```

### QQ Bot Nicknames & History

The official API returns no display name for most bots, so relays show a short id (`qq#ABC1234`) unless the platform
sends `author.username` on the event.

| Command | Effect | Who |
|---|---|---|
| `@bot 历史` | last 5 messages with id + body | `QQBOT_ADMINS` only |

- The name the platform does send is cached per group in `var/state/qqbot-nick-auto/<group_openid>`
  (`<openid>\t<nick>`, latest wins) and reused on the messages that arrive without one; an empty `username` never
  clears it.
- **No bindings**: there is no way to set a nickname by hand. The former `@bot @someone 昵称` / `@bot 291A162 昵称` /
  `@bot 昵称` commands and `var/state/qqbot-nick/<group_openid>` were removed — a message shaped like one is now
  ordinary chat and gets relayed.
- `历史` requires an id in `QQBOT_ADMINS`; everyone else gets `只有管理员能查看历史`.
- Message history lives in `var/state/qqbot-hist/<group_openid>` (`<msg_id>\t<openid>\t<text>`), trimmed to
  `QQBOT_HIST_KEEP` (50); `历史` prints the newest `QQBOT_HIST_SHOW` (5).
- Commands are consumed before dispatch, so they never reach sync.

## Webhook Auth

Set `WEBHOOK_SECRET` to require `?token=<secret>` in all webhook URLs. Failure is a real HTTP error, never a 200
with a 403 body (the platform treats 200 as delivered and stops retrying):

| Case | Status |
|------|--------|
| missing / wrong token | `403` |
| body over the size cap | `413` |
| upstream unavailable / config broken | `503` |
| qqbot callback with a bad Ed25519 signature | `401` |
| accepted | `200` (`{"op":12,"d":{}}` for qqbot events) |

**QQ Bot uses its own token**: `QQBOT_WEBHOOK_TOKEN` takes precedence over `WEBHOOK_SECRET` for `/qqbot`. Use it when
`WEBHOOK_SECRET` contains `#`, `<`, `;` — those characters truncate the callback URL on the platform side, and
`QQBOT_WEBHOOK_TOKEN` is restricted to `[A-Za-z0-9_-]` on purpose.

**Ed25519**: every qqbot callback is verified with the AppSecret-derived key (`hush-ed25519` submodule) against
`X-Signature-Ed25519` + `X-Signature-Timestamp`. `op=13` (URL verification) is answered before the event path and
also returns a signature. Verification follows `QQBOT_VERIFY_SIG`: `auto` / `1` (fail closed) / `0` (off).
Secrets are never logged — `api.sh?action=config` reports `token_masked:"***"` and scrubs `TG_API_BASE`
(`https://host/bot<TOKEN>`) through `_api_scrub_url`.

## HTTP Transport

Ayu.Core uses raw TCP + TLS for all HTTP/HTTPS requests — `nc` for TCP connections, `ssl_client` for TLS wrapping. No `wget` or `curl`.

**Why not wget**: BusyBox wget's `--post-file` reads via C standard library which treats `\x00` (null byte) as string terminator, silently truncating binary data. `--post-data` has the same limitation since shell arguments are null-terminated. Image and file transfers must preserve all byte values, making wget unsuitable for binary payloads.

**How it works**:

| Protocol | Transport |
|----------|-----------|
| HTTP (QQ API) | `cat request \| nc host port` |
| HTTPS (Telegram/Discord) | `nc host 443 -e wrapper` where wrapper pipes request through `ssl_client -s FD -n SNI` (via pipe, not shell pipe) |

The raw HTTP response is parsed to extract status code and body, with chunked transfer encoding reassembly. All internal variables use `_h` prefix to avoid hush global variable collisions.

## Regional Network Considerations

If `api.telegram.org` or `discord.com` are unreachable from your deployment environment, use a Cloudflare Worker or similar edge compute service as a forward proxy:

1. Deploy a CF Worker that proxies requests to the target API
2. Set `TG_API_HOST=your-worker.example.com` (and `DC_API_BASE` for Discord)
3. Workers deployed at the edge typically have direct peering to major API providers
4. Use `X-Ayu-Token` or similar custom headers for WAF authentication at the edge

### TLS Support

Ayu.Core uses busybox's built-in `ssl_client` for TLS negotiation. **No external SSL library or CA bundle required.**

**TLS version: 1.2 only** (BusyBox 1.37.0 `ssl_client` supports TLS 1.2 exclusively — no TLS 1.0/1.1 downgrade, no TLS 1.3).

**Supported cipher suites** (all enabled by default):

| Cipher Suite | Key Exchange | Encryption | Integrity |
|-------------|-------------|------------|-----------|
| `ECDHE-RSA-AES128-GCM-SHA256` | ECDHE | AES-128-GCM | AEAD |
| `ECDHE-ECDSA-AES128-GCM-SHA256` | ECDHE (ECDSA) | AES-128-GCM | AEAD |
| `ECDHE-RSA-AES128-CBC-SHA256` | ECDHE | AES-128-CBC | SHA256 |
| `ECDHE-ECDSA-AES128-CBC-SHA256` | ECDHE (ECDSA) | AES-128-CBC | SHA256 |
| `RSA-AES128-GCM-SHA256` | RSA | AES-128-GCM | AEAD |
| `RSA-AES128-CBC-SHA256` | RSA | AES-128-CBC | SHA256 |
| `RSA-AES256-CBC-SHA256` | RSA | AES-256-CBC | SHA256 |

**Supported curves:** P256 (secp256r1), X25519.

**Important limitations:**
- No TLS certificate validation (the server's certificate is not verified — trust is based on network layer)
- If your upstream server requires TLS 1.3 (e.g., some Cloudflare zones with minimum TLS 1.3), requests will fail at the TLS handshake stage
- Use a CF Worker or reverse proxy as intermediate if the target requires TLS 1.3

## Error Handling

hush has no `trap ERR`. Errors **prepend** at each layer (never overwrite):

```
qq.send_group: qq.send_group_message: http failed after 2 retries: http://x:8080/api/... (connection refused)
```

```sh
json_get "$resp" key || die "missing key"
# → Ayu.Core ERROR (line 23): missing key
```

> **Important**: hush has no local variables. Utility functions must use `$1` `$2` `$3` directly — assigning to named parameters (e.g., `_msg="$3"`) corrupts the caller's variables.

## Tests

```sh
# All tests (mock_http, no API keys required)
docker run --rm -v $(pwd):/ayu busybox:musl hush /ayu/test/run.sh

# Single category
docker run --rm -v $(pwd):/ayu busybox:musl hush -c "
  cd /ayu && . ./lib/core.sh && . ./test/helper.sh && . ./test/test_qq_message.sh
"
```

**486 tests, 0 failures.**

| Suite | Files | Tests |
|-------|-------|-------|
| QQ (Milky) | `test_qq_message`, `test_qq_system`, `test_qq_webhook` | 29 |
| QQ Bot (official) | `test_qqbot`, `test_qqbot_admin`, `test_qqbot_commands` | 106 |
| QQ Bot sync | `test_sync_qqbot` | 32 |
| Telegram | `test_telegram` | 16 |
| Discord | `test_discord` | 32 |
| Cross-platform sync | `test_sync`, `test_sync_tmpvars` | 29 |
| HTTP transport | `test_http`, `test_headers` | 90 |
| Security / scrubbing | `test_router_auth`, `test_webhook_auth`, `test_scrub` | 18 |
| Dispatch & API | `test_dispatch`, `test_api` | 11 |
| URL / log / maintenance | `test_url`, `test_log`, `test_maint` | 45 |

qqbot coverage splits as `test_qqbot.sh` (45: webhook entry, op=13, op=0 ACK, 401/403, dedupe),
`test_qqbot_admin.sh` (history / cached names / full-stream), `test_qqbot_commands.sh`
(13: built-in commands), `test_sync_qqbot.sh` (32: qqbot↔TG/DC relay, attachments, recall).

Tests assume the submodules are initialised (`git submodule update --init`), otherwise `test/run.sh` fails at
`hush-json/lib/json.sh`.

## Constraints

- **busybox:musl** — no bash, gawk, curl, jq, Python
- **nc + ssl_client** — raw TCP + TLS transport (replaces wget for binary-safe I/O)
- **httpd CGI** — path hardcoded to `/cgi-bin/`, `H:` does NOT enable CGI
- **hush** — no arrays, no `trap ERR`, no local variables
- **awk** — var names ≤3 chars, `"\n"` is literal
- **JSON escapes** — only `\"` and `\\` resolved natively; `\uXXXX` decoded via `utf8_decode`
- **$() trap** — functions that set `_ERROR` must not run inside subshells

## Dashboard (XML + CSS)

The dashboard is one XML document and one stylesheet, both generated by `cgi-bin/web.sh`.
There is no HTML page, no JavaScript and no external asset: the browser receives
`text/xml` plus a single `<?xml-stylesheet type="text/css"?>` instruction.

| Endpoint | Purpose |
|---|---|
| `/cgi-bin/web.sh` | the panel — overview, sync map, log tail, config on one page |
| `/cgi-bin/web.sh?page=overview\|sync\|logs\|config` | highlight one section |
| `/cgi-bin/web.sh?logs=bot\|error\|cron&lines=N` | choose the log tail (1–300 lines) |
| `/cgi-bin/web.sh?css=1` | the stylesheet (authenticated — it embeds a command nonce) |
| `/cgi-bin/act.sh?n=<nonce>&op=pause\|resume` | pause/resume auto-refresh — the only write |
| `POST /cgi-bin/web.sh` with body `token=<secret>` | sign in from a script (303 + `ayu` cookie) |
| `GET /cgi-bin/web.sh?token=<secret>` | sign in from the address bar (same check, 303 + cookie) |

The read-only JSON API (`/cgi-bin/api.sh`) is unchanged and still available to scripts:

| Endpoint | Purpose |
|---|---|
| `/cgi-bin/api.sh?action=status` | uptime, platforms, state/log/media sizes, maintenance timestamp |
| `/cgi-bin/api.sh?action=logs&which=bot\|cron\|error&lines=N` | tail of a log file (already scrubbed) |
| `/cgi-bin/api.sh?action=sync` | configured sync pairs |
| `/cgi-bin/api.sh?action=config` | non-secret config (token shown as a flag) |

Pass `&token=<WEBHOOK_SECRET>` or an `X-Ayu-Token` header when `WEBHOOK_SECRET` is set; secrets are only ever reported as a configured/not-configured flag.

### Why XML, and what it costs

Choosing XML is not cosmetic. An XML document is data with a stylesheet attached, so
the panel has nowhere to hide logic and the whole presentation stays in one file.
The bill comes due in four places, all measured in Chromium rather than assumed:

- **`class` means nothing.** There is no HTML parser to give it meaning, so `.foo`
  selectors silently never match. The sheet uses element names and `[attr="value"]`
  selectors only — see `lib/render.sh`, and `test/test_web.sh` guards against a
  `.class` selector creeping back in.
- **No form controls.** `<a>` is not a link, `<input>` is not a field, and a click
  submits nothing; CSS keeps no state either, only the momentary `:active`, so typed
  characters cannot be accumulated. Sign-in therefore cannot live inside the page:
  browsers paste `?token=<secret>` into the address bar, scripts POST the body.
  Navigation is by URL. The one clickable surface is a pad whose `:active` state
  loads a CSS background image carrying a nonce — that request *is* the click.
- **No `<meta http-equiv="refresh">`.** Auto-refresh is the HTTP `Refresh:` header:
  5 s normally, 30 s while paused (so the resume click can still be observed).
- **3D is all CSS.** Six transformed faces per block under `perspective` +
  `preserve-3d` + `@keyframes` rotation, after CSS-Minecraft. Hovering a block
  freezes it.

Auth: success sets `ayu=<sha256(token)>` as an HttpOnly cookie, so the plaintext
secret never sits in the browser. Two entry points — POST body for scripts, GET
`?token=` for browsers (httpd runs without `-v`, so request lines are not logged
either way; the pasted URL does stay in browser history). A `prod` tree without
`WEBHOOK_SECRET` answers 503 instead of serving an open panel.

## Maintenance

`plugin/maint/clean.sh` runs at boot (`cgi-bin/start.sh`) and daily via `etc/crontab`:

- rotates `var/log/{bot,error,cron}.log` when they exceed 5/5/2 MB (keeps `.1`/`.2`)
- removes abandoned scratch files in `/tmp` (`ayu-*`, `tg-up-*`, `tg-api.*`, `dc-*-resp*`, …)
- trims the routing table in `var/state/msg-map{,-rev}`: drops entries older than
  **30 days** and caps each conversation at **5000** entries (`maint_trim_state`)
- never deletes `dc-cursor`, chat content, or the forwarded media cache in `/tmp/img`
- logs a warning when `var/state` still grows past 3 GB after trimming

Tunables (env or `etc/config.sh`):

| Variable | Default | Meaning |
|---|---|---|
| `MAINT_STATE_KEEP_DAYS` | `30` | drop map entries older than N days |
| `MAINT_STATE_KEEP_ITEMS` | `5000` | hard cap per conversation directory |
| `MAINT_STATE_MIN_ITEMS` | `200` | never trim a directory below this |
| `MAINT_STATE_DRY` | `0` | `1` = report only, delete nothing |
