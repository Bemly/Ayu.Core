# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Target Runtime

All code runs inside **busybox:musl** (1.37.0) Docker container via OrbStack. No bash, no gawk, no curl, no jq, no Python. Available: hush shell, busybox awk, sed, grep, nc, ssl_client, httpd.

**Critical: Always test inside the busybox container, never on macOS.** macOS BSD tools differ significantly from BusyBox implementations.

```sh
docker cp script.sh busybox-musl:/tmp/ && docker exec busybox-musl sh /tmp/script.sh
docker run --rm -v $(pwd):/test busybox:musl sh /test/test/run.sh
```

## Repo Structure

```
Ayu.Core/                  # SNS bot framework (this repo)
├── hush-json/             # → git submodule: pure hush JSON interpreter
```

## Submodule

`hush-json/` is a git submodule → https://github.com/Bemly/hush-json. After changes to hush-json, update the pin in Ayu.Core:

```sh
cd hush-json && git pull origin main && cd .. && git add hush-json && git commit -m "update hush-json"
```

## Git workflow

**IMPORTANT: After ANY changes to either repo, commit AND push to GitHub immediately.**

- hush-json: https://github.com/Bemly/hush-json
- Ayu.Core: https://github.com/Bemly/Ayu.Core

```sh
# In hush-json: commit and push
cd /Users/bemly/cchaha/hush-json
git add -A && git commit -m "<message>" && git push

# In Ayu.Core: commit, push, and update submodule if hush-json changed
cd /Users/bemly/cchaha/Ayu.Core
git add -A && git commit -m "<message>" && git push
```

## BusyBox httpd CGI

**CGI path is hardcoded to `/cgi-bin/`.** `H:` directive only does URL rewriting (static files), NOT CGI. The repo uses `cgi-bin/` directory directly — no wrapper, no `H:` config needed. httpd auto-detects and executes scripts under `<home>/cgi-bin/`.

See memory: busybox-httpd-cgi.md

## BusyBox awk limitations

- Function signatures must be short: total line from `function` to `{` under ~55 chars
- Use 1-3 char variable names
- See memory: busybox-awk-limits.md

## NAS Production Testing

**All network and connectivity tests on the NAS MUST run inside the `Ayu` Docker container, NEVER on the NAS host.**

```sh
# RIGHT: inside the container
ssh fnOS 'docker exec Ayu sh -c "wget -q -O- https://tghook.bemly.moe/..."'

# WRONG: on the NAS host directly
ssh fnOS 'curl ...'  # GNU curl != busybox wget
```

## Production Verification Checklist

**After EVERY deployment to NAS, run ALL of these from inside the `Ayu` container:**

```sh
# 1. Auth: reject missing/wrong token (MUST return 403)
sudo docker exec Ayu wget -q -O- 'http://127.0.0.1:6160/cgi-bin/router.sh/qq' --post-data='{}'
sudo docker exec Ayu wget -q -O- 'http://127.0.0.1:6160/cgi-bin/router.sh/qq?token=bad' --post-data='{}'

# 2. Auth: accept correct token
sudo docker exec Ayu wget -q -O- \
  'http://127.0.0.1:6160/cgi-bin/router.sh/qq?token=REDACTED' \
  --post-data='{"event_type":"message_receive","data":{"sender_id":1,"message_scene":"group","group_id":1,"segments":[{"type":"text","data":{"text":"test"}}]}}' \
  --header='Content-Type: application/json'
# Expected: {"status":"ok"}

# 3. QQ API connectivity
sudo docker exec Ayu wget -q -O- -T 5 http://host.docker.internal:616/api/get_group_list \
  --header='Authorization: Bearer REDACTED' \
  --header='Content-Type: application/json' --post-data='{}'
# Expected: {"status":"ok","retcode":0,...}

# 4. TG API connectivity (via CF Worker, requires X-Ayu-Token)
sudo docker exec Ayu wget -q -O- -T 5 \
  --header='X-Ayu-Token: REDACTED' \
  https://tghook.bemly.moe/botREDACTED/getMe
# Expected: {"ok":true,"result":{...}}

# 5. Sync config exists
sudo docker exec Ayu cat /test/etc/sync.conf
```

**All checks must pass before considering deployment complete.**

**Why:** The NAS host has GNU wget and curl with different TLS/proxy/cert behavior than the busybox:musl container. Tests that pass on the host don't guarantee the container can do the same thing. This has caused multiple debugging dead ends. See memory: feedback_test_busybox.md

## Deploy workflow

**Modify locally → test in local Docker → then deploy to NAS. Never edit directly on NAS.**

```sh
# 1. Edit files locally
# 2. Test in local Docker
docker run --rm -v $(pwd):/test busybox:musl hush /test/test/run.sh
# 3. Only after 0 failures, deploy to NAS
sshpass -p '...' scp file.sh fnOS:/tmp/ && \
  ssh fnOS 'sudo cp /tmp/file.sh /vol1/1000/Ayu/path/file.sh && sudo chmod +x /vol1/1000/Ayu/path/file.sh'
# 4. Fix ALL permissions (CGI scripts silently fail without +x)
ssh fnOS 'sudo find /vol1/1000/Ayu -name "*.sh" -exec chmod +x {} \; && sudo chmod 777 /vol1/1000/Ayu/var/log'
# 5. Restart httpd on NAS (kill httpd → container exits → restart container)
ssh fnOS 'sudo docker exec Ayu killall httpd; sudo docker start Ayu'
```

**Why `docker start Ayu` instead of `docker exec ... start.sh`:** httpd is the container's main process (pid 1). Killing it stops the container; restarting the container re-runs `start.sh` → httpd. This also ensures `docker logs Ayu` captures all output.

**Exception:** `etc/config.sh` and `etc/sync.conf` NAS values (tokens, hostnames) differ from local defaults. These can be edited on NAS directly or via env vars.

**Why:** Editing on NAS risks syntax errors in production. Local Docker catches them first.

## Ayu container setup (NAS)

The Ayu container MUST be created with:

```sh
docker run -d --name Ayu \
  --add-host host.docker.internal:host-gateway \
  -p 6160:6160 \
  -v /vol1/1000/Ayu:/test \
  -v /vol1/1000/Lagrange/img:/tmp/img \
  busybox:musl sh /test/cgi-bin/start.sh
```

**Critical requirements:**
- `sh /test/cgi-bin/start.sh` as entrypoint (NOT `sleep infinity`) — httpd runs as pid 1, `docker logs Ayu` captures all bot activity via stderr
- **BOTH volume mounts are required:**
  - `/vol1/1000/Ayu:/test` — code and config
  - `/vol1/1000/Lagrange/img:/tmp/img` — shared with Lagrange for QQ↔TG image/file transfers. **Without this, ALL QQ CDN downloads fail** because sync.sh writes to `/tmp/img/sync-*`

**Why:** Missing `/tmp/img` mount causes silent download failures — wrapper writes to non-existent directory, file is never created, 3 retries exhaust → fallback degrades to URL-only mode (no GIF detection, no file forwarding). See 2026-05-04 incident.

## Coding patterns

- **Refactor repeated patterns into helpers**: when the same `_qq_call + json_get + error wrap` pattern appears across 20+ functions, extract ONE `_qq_api()` helper. Don't edit each copy individually.
- **Avoid `$()` for function calls that set `_ERROR`**: `$()` is a subshell, globals are lost. Use temp files.
- **`_ERROR` chain**: always prepend, never overwrite. Format: `module.func: $_ERROR`

## Cross-Platform Sync Features

The `plugin/sync.sh` handler forwards messages between QQ and Telegram bidirectionally. Each content type is handled differently per direction.

### Sticker (TG→QQ)

| Sticker Type | Format | QQ Delivery | Implementation |
|-------------|--------|-------------|----------------|
| Static (is_video=false, is_animated=false) | WEBP/PNG | Image segment | `_sync_tg_sticker_to_qq()` — download via tg_getFile → send as image |
| Video (is_video=true) | WEBM | File upload | Same function — download → `qq_file_upload_group` as `sticker.webm` |
| Animated (is_animated=true) | TGS | File upload | Same function — download → `qq_file_upload_group` as `sticker.tgs` |

**Why video/animated ≠ image**: QQ FlashTransfer returns "pic compress error" on non-static formats. WEBP is the only TG sticker format QQ can render as inline image.

### Reaction (TG→QQ)

TG `message_reaction` update → lookup msg-map file at `/test/var/state/msg-map/{chat_id}/{message_id}` → extract `group_id message_seq` → `qq_group_send_reaction` with Unicode codepoint (decimal) as type=2 code. Emoji codepoint derived via `_reaction_code()` which handles JSON-escaped `\uXXXX` (including surrogate pairs) and raw UTF-8 via `od`.

### Image (bidirectional)

| Direction | Method |
|-----------|--------|
| QQ→TG | `_sync_qq_images_to_tg()` — extract temp_url from segments → download → check GIF magic bytes → `sendAnimation` (GIF) or `sendPhoto` (static) via multipart |
| TG→QQ | `_sync_tg_photo_to_qq()` — `tg_getFile` → download → image segment with `file:///root/img/...` URI |

### File / Document (bidirectional)

| Direction | Method |
|-----------|--------|
| QQ→TG | `_sync_qq_files_to_tg()` — `qq_file_get_download_url` → download → multipart `sendDocument` |
| TG→QQ | `_sync_tg_document_to_qq()` — `tg_getFile` → download → `qq_file_upload_group` |

### Animation / GIF (TG→QQ)

`_sync_tg_animation_to_qq()` — TG converts GIF to MP4 internally → download → `qq_file_upload_group` (QQ cannot render MP4 as inline image).

### Text (bidirectional)

Text forwarded with sender attribution prefix (🐧 for QQ, ✈️ for TG) and loop prevention checks (prefix + bot sender ID).

### Voice / Record (bidirectional)

| Direction | Method |
|-----------|--------|
| QQ→TG | `_sync_qq_record_to_tg()` — extract record segment temp_url → download → multipart `sendVoice` |
| TG→QQ | `_sync_tg_voice_to_qq()` — `tg_getFile` → download → QQ record segment with `file:///root/img/...` URI |

### Video (bidirectional)

| Direction | Method |
|-----------|--------|
| QQ→TG | `_sync_qq_video_to_tg()` — extract video segment temp_url → download → multipart `sendVideo` |
| TG→QQ | `_sync_tg_video_to_qq()` — `tg_getFile` → download → QQ video segment with `file:///root/img/...` URI |

### Recall / Delete (QQ→TG only)

QQ `message_recall` event → extract `peer_id` + `message_seq` → lookup reverse map at `/test/var/state/msg-map-rev/{qq_gid}/{qq_seq}` → `tg_deleteMessage`. Both forward and reverse maps are cleaned up after deletion.

**TG→QQ recall is NOT possible**: Telegram webhooks do not include message deletion events.

### Non-forwardable Types (text label only)

These TG content types produce `[标签]` text but no file transfer: video_note `[视频笔记]`, audio `[音频: title]`, location `[位置]`, contact `[联系人]`, dice `[骰子]`, poll `[投票]`, venue `[地点]`, game `[游戏]`.

### Message Mapping

Every forwarded message stores BOTH a forward and reverse mapping:
- Forward: `/test/var/state/msg-map/{tg_chat_id}/{tg_message_id}` → `{qq_group_id} {qq_message_seq}` — enables TG→QQ reaction sync
- Reverse: `/test/var/state/msg-map-rev/{qq_group_id}/{qq_message_seq}` → `{tg_chat_id} {tg_message_id}` — enables QQ→TG recall sync

### Sync Config

`etc/sync.conf`: `source=target` per line. Format:
```
qq/group/123456=telegram/-100111          # QQ group → TG group
telegram/-100111=qq/group/123456          # TG group → QQ group
telegram/-100111=telegram/-100222/16553   # TG → TG forum topic
```

### Discord Sync (2026-05-05)

**QQ/TG → DC (real-time)**: `handler.sh` discord target case → `dc_message_create` for text, plus media forwarders in `from_qq.sh` (`_sync_qq_images_to_dc`, `_sync_qq_files_to_dc`, `_sync_qq_record_to_dc`, `_sync_qq_video_to_dc`) and `from_tg.sh` (`_sync_tg_photo_to_dc`, `_sync_tg_document_to_dc`, `_sync_tg_voice_to_dc`, `_sync_tg_video_to_dc`, `_sync_tg_sticker_to_dc`, `_sync_tg_animation_to_dc`). All media uploaded via `_sync_dc_multipart()` in `common.sh` (multipart/form-data with `payload_json` + `files[0]` parts).

**DC → QQ/TG (daily batch)**: `cgi-bin/dc-sync.sh` triggered by cron → reads `etc/sync.conf` for `discord/` sources → `dc_message_list` fetches recent messages → filters by today's date → calls `sync_dc_message()` in `from_dc.sh` which forwards text to QQ/TG targets. Skips bot's own messages via `DC_BOT_ID`.

**DC webhook**: `router.sh` now has `discord)` case → `adapter/discord/webhook.sh` → `dc_webhook_handler()` handles PING verification (type=1). Message events require Gateway (WebSocket), unsupported.

**Discord multipart format** (different from TG):
```
--boundary
Content-Disposition: form-data; name="payload_json"
Content-Type: application/json
{"content":"🐧 sender: [image]"}

--boundary
Content-Disposition: form-data; name="files[0]"; filename="img.png"
Content-Type: image/png
<binary>
--boundary--
```

**Config**: `DC_TOKEN` (bot token), `DC_BOT_ID` (bot user ID for loop prevention), `DC_API_BASE="https://discord.com/api/v10"`.

**Sync.conf format**:
```
qq/group/A=discord/ch123        # QQ→DC real-time
telegram/X=discord/ch123        # TG→DC real-time
discord/ch123=qq/group/A        # DC→QQ daily batch
```

## HTTP Transport (nc + ssl_client)

**Ayu.Core does NOT use wget.** All HTTP/HTTPS goes through `lib/http.sh` which uses raw TCP + TLS:

- **HTTP**: `cat request | nc host port`
- **HTTPS**: `nc host 443 -e wrapper.sh` where wrapper pipes through `ssl_client -s FD -n SNI`

**Why not wget**: BusyBox wget `--post-file` reads via C stdlib which treats `\x00` as string terminator, silently truncating binary data. `--post-data` has the same issue (shell args are null-terminated). Images and files must preserve all byte values. See memory: wget-binary-null-byte.md, nc-ssl-client.md.

All internal variables in `http.sh` use `_h` prefix (`_hraw`, `_hbody`, etc.) to avoid hush global variable collisions. **Never add variables named `_raw`, `_body`, or `_res` to http.sh** — they will corrupt callers that use those names.

## Proxy

macOS proxy at 127.0.0.1:7890. Pull images with:
```sh
HTTP_PROXY=http://127.0.0.1:7890 HTTPS_PROXY=http://127.0.0.1:7890 docker pull <image>
```

## Commit rule

**After EVERY file change (code, doc, config, CLAUDE.md itself), commit AND push immediately. No exceptions.**

```
git add -A && git commit -m "<message>" && git push
```

Do NOT batch multiple unrelated changes into one commit. Do NOT wait for the user to ask. If a file was edited, commit it right after.
