![# Ayu.Core](https://socialify.git.ci/Bemly/Ayu.Core/image?description=1&font=Raleway&language=1&logo=https%3A%2F%2Fraw.githubusercontent.com%2FBemly%2FAyu.Core%2Frefs%2Fheads%2Fmain%2Fwebui%2Flogo.jpg&name=1&owner=1&pattern=Diagonal+Stripes&theme=Dark)

[![test](https://github.com/Bemly/Ayu.Core/actions/workflows/test.yml/badge.svg)](https://github.com/Bemly/Ayu.Core/actions/workflows/test.yml)

Pure shell SNS Bot framework. Runs in busybox:musl container, hush + httpd CGI + raw TLS transport + [hush-json](https://github.com/Bemly/hush-json).

> [中文文档](README.zh.md)

## Adapter Coverage

| Platform | Endpoints | Functions | Reference |
|----------|-----------|-----------|-----------|
| QQ (LagrangeV2.Milky) | 29/29 | 27 | [adapter/qq/README.md](adapter/qq/README.md) |
| Telegram Bot API | 169/169 | 169 | [adapter/telegram/README.md](adapter/telegram/README.md) |
| Discord REST API v10 | 185 bot API | 135 | [adapter/discord/README.md](adapter/discord/README.md) |

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
│   ├── qq/                 # QQ — 6 files, 15 segment types, 8 event types
│   ├── telegram/           # Telegram — 17 files, 20 Update types, 18 content types
│   └── discord/            # Discord — 18 files, 135 functions (REST + webhook)
├── plugin/                 # Business logic
│   └── sync/               # Cross-platform sync + dc-sync.sh (crond entry)
├── webui/                  # Dashboard (Luolita SFC framework)
├── etc/                    # config, rules, crontab, sync.conf, README
└── test/                   # 141 tests, 0 failures (mock_http, no API keys)
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
```

## Configuration

```sh
# etc/config.sh — all values can be overridden via environment variables
QQ_HOST="host.docker.internal"   # bridge: host.docker.internal, host: 127.0.0.1
QQ_PORT="616"
QQ_TOKEN=""                      # set via env or config.nas.sh

TG_TOKEN=""                      # Bot token from @BotFather
TG_API_HOST="api.telegram.org"   # use a CF Worker for network accessibility
TG_API_SECRET=""                 # X-Ayu-Token header for edge authentication

DC_TOKEN=""
DC_BOT_ID=""                     # Set to skip forwarding bot's own messages (loop prevention)

BOT_PORT="6160"
WEBHOOK_SECRET=""                # if set, require ?token=<secret> in webhook URL
_LOG_LEVEL="1"                   # 0=trace, 1=info, 2=warn, 3=err
```

> Never commit secrets. Use `etc/config.nas.sh` (gitignored) for production values.  
> See `etc/config.nas.sh` for full production example.

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
```

## Message Dispatch

`etc/rules` — one rule per line: `<pattern>|<handler_file>|<handler_func>`

```
/ping|qq/handler.sh|handler_ping
/echo|qq/handler.sh|handler_echo
*|../plugin/sync/handler.sh|sync_handler
```

Rules are matched first-to-last. Commands match first; the `*` fallback forwards to cross-platform sync.

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

## Webhook Auth

Set `WEBHOOK_SECRET` to require `?token=<secret>` in all webhook URLs. Router returns 403 without it.

The token supports special characters (`#`, `<`, `;`) via URL encoding — `url_encode`/`url_decode` handle encoding automatically.

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
docker run --rm -v $(pwd):/test busybox:musl hush /test/test/run.sh

# Single category
docker run --rm -v $(pwd):/test busybox:musl hush -c "
  cd /test && . ./lib/core.sh && . ./test/helper.sh && . ./test/test_qq_message.sh
"
```

**141 tests, 0 failures** — QQ(14) + Telegram(6) + Discord(26) + HTTP(4) + Dispatch(2) + Sync(17) + URL(26) + Log(4) + Auth(5) + Webhook(16)

## Constraints

- **busybox:musl** — no bash, gawk, curl, jq, Python
- **nc + ssl_client** — raw TCP + TLS transport (replaces wget for binary-safe I/O)
- **httpd CGI** — path hardcoded to `/cgi-bin/`, `H:` does NOT enable CGI
- **hush** — no arrays, no `trap ERR`, no local variables
- **awk** — var names ≤3 chars, `"\n"` is literal
- **JSON escapes** — only `\"` and `\\` resolved natively; `\uXXXX` decoded via `utf8_decode`
- **$() trap** — functions that set `_ERROR` must not run inside subshells
