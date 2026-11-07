# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Target Runtime

All code runs inside **busybox:musl** (1.37.0) Docker container via OrbStack. No bash, no gawk, no curl, no jq, no Python. Available: hush shell, busybox awk, sed, grep, nc, ssl_client, httpd.

**Critical: Always test inside the busybox container, never on macOS.** macOS BSD tools differ significantly from BusyBox implementations.

```sh
docker cp script.sh busybox-musl:/tmp/ && docker exec busybox-musl sh /tmp/script.sh
docker run --rm -v $(pwd):/ayu busybox:musl sh /ayu/test/run.sh
```

## Repo Structure

```
Ayu.Core/                  # SNS bot framework (this repo)
├── adapter/               # one directory per platform
│   ├── qq/                #   Milky/Lagrange (LLOneBot)  — local HTTP, numeric QQ ids
│   ├── qqbot/             #   QQ official OpenAPI v2    — webhook, openid, Ed25519
│   ├── telegram/          #   Bot API
│   └── discord/           #   Bot API + webhook
├── plugin/sync/           # cross-platform relay (from_qq / from_tg / from_qqbot / from_dc)
├── plugin/maint/          # daily rotation + var/state trim (cron)
├── lib/                   # http, dispatch, json helpers, log
├── cgi-bin/router.sh      # single httpd CGI entry, routes by platform
├── etc/                   # config.sh (empty defaults) + rules + sync.conf + crontab
├── hush-json/             # → git submodule: pure hush JSON interpreter
└── hush-ed25519/          # → git submodule: Ed25519 sign/verify for QQ Bot callbacks
```

Adapter size (functions in `*.sh`, `git ls-files` count as of `990fe77`):

| Adapter | Files | Functions | Transport |
|---------|-------|-----------|-----------|
| `qq` (Milky) | 7 | 39 | local HTTP, Bearer `QQ_TOKEN` |
| `qqbot` (official v2) | 9 | 125 | webhook in + HTTPS API out |
| `telegram` | 17 | 175 | Bot API long-poll-free webhook |
| `discord` | 19 | 143 | Bot API + webhook |

## Submodule

`hush-json/` → https://github.com/Bemly/hush-json, `hush-ed25519/` → https://github.com/Bemly/hush-ed25519.
Both are pinned by commit (`160000`) — never flatten their contents into the main tree.
A fresh clone MUST run `git submodule update --init`, otherwise `test/run.sh` dies with
`can't open '/ayu/hush-json/lib/json.sh'`.

After changes to hush-json, update the pin in Ayu.Core:

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
sudo docker exec Ayu wget -q -O- 'http://host.docker.internal:6160/cgi-bin/router.sh/qq' --post-data='{}'
sudo docker exec Ayu wget -q -O- 'http://host.docker.internal:6160/cgi-bin/router.sh/qq?token=bad' --post-data='{}'

# 2. Auth: accept correct token
sudo docker exec Ayu wget -q -O- \
  'http://host.docker.internal:6160/cgi-bin/router.sh/qq?token=REDACTED' \
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
sudo docker exec Ayu cat /ayu/etc/sync.conf
```

**All checks must pass before considering deployment complete.**

**Why:** The NAS host has GNU wget and curl with different TLS/proxy/cert behavior than the busybox:musl container. Tests that pass on the host don't guarantee the container can do the same thing. This has caused multiple debugging dead ends. See memory: feedback_test_busybox.md

## Deploy workflow

**Modify locally → test in local Docker → then deploy to NAS. Never edit directly on NAS.**

```sh
# 1. Edit files locally
# 2. Test in local Docker
docker run --rm -v $(pwd):/ayu busybox:musl hush /ayu/test/run.sh
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
  -v /vol1/1000/Ayu:/ayu \
  -v /vol1/1000/Lagrange/img:/tmp/img \
  busybox:musl sh /ayu/cgi-bin/start.sh
```

**Critical requirements:**
- `sh /ayu/cgi-bin/start.sh` as entrypoint (NOT `sleep infinity`) — httpd runs as pid 1, `docker logs Ayu` captures all bot activity via stderr
- **BOTH volume mounts are required:**
  - `/vol1/1000/Ayu:/ayu` — code and config
  - `/vol1/1000/Lagrange/img:/tmp/img` — shared with the QQ backend (LLOneBot) for QQ↔TG image/file transfers. **Without this, ALL QQ CDN downloads fail** because sync.sh writes to `/tmp/img/sync-*`. The LLOneBot container must ALSO mount this same directory at `/root/img` (read-only is fine) so that `file:///root/img/...` URIs in `send_group_message` / `upload_group_file` resolve.

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

### Media (TG→QQ Bot, official API)

The `qqbot` target in `plugin/sync/handler.sh` sends text and then calls `_sync_tg_media_to_qqbot()` (`from_tg.sh`), which downloads via `tg_getFile` and re-uploads as base64 `file_data` with `file_type`: 1 image / 2 video / 3 voice / 4 file.

| TG content | `file_type` | Upload name |
| --- | --- | --- |
| Static sticker (`is_video=false`) | 1 | `sticker.webp` |
| Video sticker (`is_video=true`) | 2 | `sticker.webm` |
| Lottie sticker (`is_animated=true`) | 4 | `sticker.tgs` |
| `photo[]` (largest size) | 1 | `photo.jpg` |
| `animation` (mime-dependent) | 1 / 2 | `animation.gif` / `animation.mp4` |
| video / voice / audio / document | 2 / 3 / 3 / 4 | `video.mp4` / `voice.ogg` / original name |

No URL hand-off is possible: the TG download URL embeds our bot token and only answers with the CF worker's `X-Ayu-Token` header, which the QQ side cannot send. Above `QQBOT_FILE_DATA_MAX` (5 MB) the relay logs and skips — never "degrades" an image into a file, since that hides the failure behind a different-looking result. `channel/*` has no media upload endpoint and is skipped with `log_debug`.

**Why the relay used to look broken**: the qqbot target only sent text, so `tg_extract_text()`'s label (`[贴纸: ⭐]`) arrived alone and the sticker itself never left Telegram.


### Reaction (TG→QQ)

TG `message_reaction` update → lookup msg-map file at `/ayu/var/state/msg-map/{chat_id}/{message_id}` → extract `group_id message_seq` → `qq_group_send_reaction` with Unicode codepoint (decimal) as type=2 code. Emoji codepoint derived via `_reaction_code()` which handles JSON-escaped `\uXXXX` (including surrogate pairs) and raw UTF-8 via `od`.

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

QQ `message_recall` event → extract `peer_id` + `message_seq` → lookup reverse map at `/ayu/var/state/msg-map-rev/{qq_gid}/{qq_seq}` → `tg_deleteMessage`. Both forward and reverse maps are cleaned up after deletion.

**TG→QQ recall is NOT possible**: Telegram webhooks do not include message deletion events.

### Non-forwardable Types (text label only)

These TG content types produce `[标签]` text but no file transfer: video_note `[视频笔记]`, audio `[音频: title]`, location `[位置]`, contact `[联系人]`, dice `[骰子]`, poll `[投票]`, venue `[地点]`, game `[游戏]`.

### Message Mapping

Every forwarded message stores BOTH a forward and reverse mapping:
- Forward: `/ayu/var/state/msg-map/{tg_chat_id}/{tg_message_id}` → `{qq_group_id} {qq_message_seq}` — enables TG→QQ reaction sync
- Reverse: `/ayu/var/state/msg-map-rev/{qq_group_id}/{qq_message_seq}` → `{tg_chat_id} {tg_message_id}` — enables QQ→TG recall sync

### Sync Config

`etc/sync.conf`: `source=target` per line. Format:
```
qq/group/123456=telegram/-100111           # QQ group → TG group
telegram/-100111=qq/group/123456           # TG group → QQ group
telegram/-100111=telegram/-100222/16553    # TG → TG forum topic
qqbot/group/<group_openid>=telegram/-100111 # QQ Bot group → TG group
telegram/-100111=qqbot/group/<group_openid> # TG → QQ Bot group
discord/ch123456=qqbot/channel/<channel_id>   # DC channel → QQ Bot channel
```

QQ Bot targets: `qqbot/group/<group_openid>`, `qqbot/private/<user_openid>`, `qqbot/channel/<channel_id>`.

### Rules with platform prefix

`etc/rules` lines are `[<platform>:]<pattern>|<script>|<func>`. `dispatch()` in `lib/dispatch.sh`
accepts exactly four prefixes: `qq:`, `qqbot:`, `telegram:`, `discord:`. Without a prefix the rule
matches every platform (legacy behaviour), so platform-specific commands MUST be prefixed:

```
qqbot:/ping|qqbot/handler.sh|qqbot_handler_ping
/ping|qq/handler.sh|handler_ping
*|../plugin/sync/handler.sh|sync_handler
```

Note `router.sh` has two `case` blocks (platform detection + per-platform dispatch). Adding a platform
means touching both, otherwise requests are detected but never handled (`unknown platform: qqbot`).

### QQ Bot adapter (official OpenAPI v2)

Webhook-only (no WebSocket gateway). Entry: `router.sh` → `adapter/qqbot/webhook.sh:qqbot_webhook()`.

| File | Responsibility |
|------|----------------|
| `core.sh` | token cache/refresh, `_qqbot_api`, `qqbot_seg` (URL-safe encoding), sent-id tracking |
| `sign.sh` | `qqbot_ed_load/usable/sign/verify`, `qqbot_signature_enabled` (Ed25519, seed = `QQBOT_APP_SECRET`) |
| `webhook.sh` | op=13 URL validation, op=0 events, dedupe (`qqbot_seen/remember`), attachment rendering |
| `message.sh` | group / c2c / channel send, recall, media & file upload (29 functions) |
| `group.sh` / `guild.sh` | group + channel management APIs |
| `asset.sh` | media-images, `generate_url_link`, menu, panels, user upload |
| `admin.sh` | nickname binding, history, `qqbot_admin_handle` |
| `handler.sh` | builtin commands `/ping` `/echo` `/info` `/recall` |

Conventions and gotchas:

- IDs are `openid` / `group_openid` — never numeric QQ numbers. The relay icon is `🅠` (loop prevention must treat `qqbot` separately from `🐧`).
- `_qqbot_api <method> <path> <body> <tag>` handles token refresh once on 401 then retries.
- Webhook events carry media **only** as `attachments[]` (url + content_type): `plugin/sync/from_qqbot.sh` downloads once and re-uploads via `_sync_tg_multipart` / `_sync_dc_multipart`; voice prefers `voice_wav_url` (SILK is unplayable).
- Full-stream `GROUP_MESSAGE_CREATE` (whole-group messages, not just @-mentions) is handled in `admin.sh`; when `QQBOT_BOT_OPENID` is set, commands must @ the bot.
- Auth is a separate token (`QQBOT_WEBHOOK_TOKEN`, URL-safe alphabet) with Ed25519 verification on every callback — see `SECURITY.md`.
- Tests: `test/test_qqbot.sh` (45), `test/test_qqbot_admin.sh` (48), `test/test_qqbot_commands.sh` (13), `test/test_sync_qqbot.sh` (36).

### Discord Sync (2026-05-05)

**QQ/TG → DC (real-time)**: `handler.sh` discord target case → `dc_message_create` for text, plus media forwarders in `from_qq.sh` (`_sync_qq_images_to_dc`, `_sync_qq_files_to_dc`, `_sync_qq_record_to_dc`, `_sync_qq_video_to_dc`) and `from_tg.sh` (`_sync_tg_photo_to_dc`, `_sync_tg_document_to_dc`, `_sync_tg_voice_to_dc`, `_sync_tg_video_to_dc`, `_sync_tg_sticker_to_dc`, `_sync_tg_animation_to_dc`). All media uploaded via `_sync_dc_multipart()` in `common.sh` (multipart/form-data with `payload_json` + `files[0]` parts).

**DC → QQ/TG (daily batch)**: `crond` runs `dc_batch_run()` in `plugin/sync/dc-sync.sh` daily via `etc/crontab` → reads `etc/sync.conf` for `discord/` sources → `dc_message_list` fetches recent messages → filters by today's date → calls `sync_dc_message()` in `from_dc.sh` which forwards text to QQ/TG targets. Skips bot's own messages via `DC_BOT_ID`.

**DC webhook**: `router.sh` now has `discord)` case → `adapter/discord/webhook.sh` → `dc_webhook_handler()` handles PING verification (type=1). Message events require Gateway (WebSocket), unsupported.

### QQ Bot Sender Names / History (2026-11-07)

The official API never returns a nickname — only a per-bot `member_openid`. So every relayed line shows a short id, and a group admin can bind a name to it (`adapter/qqbot/admin.sh`):

```
@bot @someone 宝宝        # admin: bind somebody else by mention
@bot 291A162 宝宝         # admin: bind somebody else by the 7-char prefix
@bot 蓝莓小果冻           # anyone: rename yourself
@bot 历史                 # admin: last 5 messages with id + body
```

- Bindings: `var/state/qqbot-nick/<group_openid>`, one `<openid>\t<nick>` per line; latest wins, unlimited rewrites. Read by both the adapter (`qqbot_nick_get`) and the relay (`_sync_qqbot_nick` in `plugin/sync/common.sh`), so a bound name appears in `qqbot` senders as `宝宝(qq#ABC1234)`.
- Permissions: the two-target forms (mention / 7-char prefix) and `历史` are admin-only — only ids in `QQBOT_ADMINS` (`etc/config.sh`, space separated, full openid or ≥7-char prefix); others get `只有管理员能绑定昵称` / `只有管理员能查看历史`. `@bot 昵称` renames the **sender** and is open to every member (writes the event's own openid, so it cannot touch anybody else). Member openids are per-group, so an admin id is group-scoped.
- Self-rename only fires for a single word (no space, not a lone hex id, ≤48 bytes); anything else falls through to the relay as ordinary chatter. Replies: `已设置你的昵称` / `已修改你的昵称` / `昵称未变化`.
- Message log: `var/state/qqbot-hist/<group_openid>`, `<msg_id>\t<openid>\t<text>`, trimmed to `QQBOT_HIST_KEEP` (50). Only group messages are logged; `历史` prints the newest `QQBOT_HIST_SHOW` (5).
- Admin commands are consumed before `dispatch`/sync, so they are never relayed to TG/DC.
- `qqbot_render_content` also strips the markdown payload: `<@openid>` → `@<nick>` or `@qq#<first7>`, `<faceType=…,ext="<base64 json>">` → its `text` (e.g. `[聪明]`).

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
