# Ayu.Core

> [中文文档](README.zh.md)

Pure shell SNS Bot framework. Runs in busybox:musl container, hush + httpd CGI + raw TLS transport + [hush-json](https://github.com/Bemly/hush-json).

[![test](https://github.com/Bemly/Ayu.Core/actions/workflows/test.yml/badge.svg)](https://github.com/Bemly/Ayu.Core/actions/workflows/test.yml)

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
│   ├── start.sh            # Launch httpd
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
│   └── discord/            # Discord — 17 files (REST only)
├── plugin/                 # Business logic
│   └── sync.sh             # Cross-platform sync (text + image + file + sticker + reaction, bidirectional)
├── etc/                    # config.sh, rules, sync.conf, config.nas.sh (gitignored)
└── test/                   # 129 tests, 0 failures (mock_http, no API keys)
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
*|../plugin/sync.sh|sync_handler
```

Rules are matched first-to-last. Commands match first; the `*` fallback forwards to cross-platform sync.

## Cross-Platform Sync

Messages from one platform auto-forward to the others. Images and files are downloaded locally then re-uploaded (not URL pass-through), preserving content integrity end-to-end.

| From→To | Prefix | Loop Prevention |
|---------|--------|-----------------|
| QQ→TG | `🐧 用户: 消息` | emoji prefix + bot sender ID |
| TG→QQ | `✈️ 用户: 消息` | emoji prefix + bot sender ID |
| →DC | `👾 用户: 消息` | (not implemented) |

**Content type handling**:

| Type | QQ→TG | TG→QQ |
|------|-------|-------|
| Text | `sendMessage` with 🐧 prefix | QQ text segment with ✈️ prefix |
| Image | Download → GIF detection → `sendAnimation`/`sendPhoto` | Download → image segment (`file://` URI) |
| File | Download → multipart `sendDocument` | Download → `upload_group_file` |
| Sticker | — | Static WEBP → image; Video WEBM/TGS → file |
| Reaction | — | `message_reaction` → msg-map lookup → `send_group_message_reaction` |
| GIF/Animation | — | Download → `upload_group_file` (TG converts to MP4) |
| Voice | Download `temp_url` → multipart `sendVoice` | Download → QQ `record` segment |
| Video | Download `temp_url` → multipart `sendVideo` | Download → QQ `video` segment |
| Reply | Context in text | Context in text |
| Forward | `[转发]` prefix | `[转发]` prefix |
| Recall | `message_recall` → rev-map lookup → `deleteMessage` | — (TG webhooks don't include deletions) |
| Location/Contact/Dice/Poll | Text label | Text label |

**1. Configure mappings** in `etc/sync.conf`:

```
qq/group/123456=telegram/-100111            # QQ group → TG group
qq/group/123456=telegram/-100111/16553      # QQ group → TG forum topic
telegram/-100111=qq/group/123456            # TG group → QQ group
```

**2. Enable** with the `*` rule in `etc/rules` (included by default).

**Limitations**:
- Discord→QQ/TG requires Gateway (WebSocket), not feasible in pure shell
- TG→QQ recall is not possible (TG webhooks don't include deletion events)
- TG Bot API `getFile` has a **20MB** file size limit — files larger than 20MB (e.g., long videos) can be received via webhook but cannot be downloaded for forwarding. These are skipped with a log message.

QQ↔Telegram is fully bidirectional — text, image, file, voice, video, sticker, reaction, recall (QQ→TG).

## Webhook Auth

Set `WEBHOOK_SECRET` to require `?token=<secret>` in all webhook URLs. Router returns 403 without it.

The token supports special characters (`#`, `<`, `;`) via URL encoding — `url_encode`/`url_decode` handle encoding automatically.

## HTTP Transport

Ayu.Core uses raw TCP + TLS for all HTTP/HTTPS requests — `nc` for TCP connections, `ssl_client` for TLS wrapping. No `wget` or `curl`.

**Why not wget**: BusyBox wget's `--post-file` reads via C standard library which treats `\x00` (null byte) as string terminator, silently truncating binary data. `--post-data` has the same limitation since shell arguments are null-terminated. Image and file transfers must preserve all byte values, making wget unsuitable for binary payloads.

**How it works**:

| Protocol | Transport |
|----------|-----------|
| HTTP (QQ API) | `cat request | nc host port` |
| HTTPS (Telegram/Discord) | `nc host 443 -e wrapper` where wrapper pipes request through `ssl_client -s FD -n SNI` |

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

**129 tests, 0 failures** — QQ(14) + Telegram(6) + Discord(26) + HTTP(4) + Dispatch(2) + Sync(12) + URL(26) + Log(4) + Auth(5) + Webhook(16)

## Constraints

- **busybox:musl** — no bash, gawk, curl, jq, Python
- **nc + ssl_client** — raw TCP + TLS transport (replaces wget for binary-safe I/O)
- **httpd CGI** — path hardcoded to `/cgi-bin/`, `H:` does NOT enable CGI
- **hush** — no arrays, no `trap ERR`, no local variables
- **awk** — var names ≤3 chars, `"\n"` is literal
- **JSON escapes** — only `\"` and `\\` resolved natively; `\uXXXX` decoded via `utf8_decode`
- **$() trap** — functions that set `_ERROR` must not run inside subshells
