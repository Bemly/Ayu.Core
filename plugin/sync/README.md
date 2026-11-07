# Cross-Platform Sync

> [中文](README.zh.md)

Messages from one platform auto-forward to the others. Images and files are downloaded locally then re-uploaded (not URL pass-through), preserving content integrity end-to-end.

## Architecture

```
plugin/sync/
├── common.sh       — Shared utilities, adapter imports
├── from_qq.sh      — QQ source → TG/DC forwarders
├── from_tg.sh      — TG source → QQ/DC forwarders
├── from_qqbot.sh   — QQ Bot source → TG/DC forwarders (media from attachments[])
├── from_dc.sh      — DC source → QQ/TG/QQBot forwarders
├── dc-sync.sh      — Daily DC batch puller (cron)
└── handler.sh      — sync_handler main router
```

## Direction & Loop Prevention

| From→To | Prefix | Loop Prevention |
|---------|--------|-----------------|
| QQ→TG | `🐧 用户: 消息` | emoji prefix + bot sender ID |
| TG→QQ | `✈️ 用户: 消息` | emoji prefix + bot sender ID |
| QQ→DC | `🐧 用户: 消息` | emoji prefix + bot sender ID |
| TG→DC | `✈️ 用户: 消息` | emoji prefix + bot sender ID |
| DC→QQ | `👾 用户: 消息` | sender ID (`DC_BOT_ID`) |
| DC→TG | `👾 用户: 消息` | sender ID (`DC_BOT_ID`) |
| QQ Bot→TG | `🅠 用户: 消息` | emoji prefix (QQ Bot has no numeric sender ID) |
| QQ Bot→DC | `🅠 用户: 消息` | emoji prefix |
| DC→QQ Bot | `👾 用户: 消息` | sender ID (`DC_BOT_ID`) |

QQ Bot (`qqbot`) is a distinct adapter from QQ (Milky): IDs are `openid`/`group_openid`, not numeric
QQ numbers, and the transport is a webhook instead of a local HTTP API. Its relay icon is `🅠`, so
`handler.sh` loop-prevention treats it independently of `🐧`.

## Content Type Handling

| Type | QQ→TG | TG→QQ | QQ→DC | TG→DC | DC→QQ/TG |
|------|-------|-------|-------|-------|----------|
| Text | `sendMessage` + 🐧 | QQ text segment + ✈️ | `dc_message_create` + 🐧 | `dc_message_create` + ✈️ | Text + 👾 (daily batch) |
| Image | Download → GIF detect → `sendAnimation`/`sendPhoto` | Download → image segment | Download → multipart POST | Download → multipart POST | — |
| File | Download → multipart `sendDocument` | Download → `upload_group_file` | Download → multipart POST | Download → multipart POST | — |
| Sticker | — | Static WEBP → image; Video WEBM/TGS → file | — | Static → image; Video → file | — |
| Reaction | — | msg-map lookup → `send_group_message_reaction` | — | — | — |
| GIF | — | Download → `upload_group_file` (MP4) | — | Download → multipart POST | — |
| Voice | Download → multipart `sendVoice` | Download → QQ `record` | Download → multipart POST | Download → multipart POST | — |
| Video | Download → multipart `sendVideo` | Download → QQ `video` | Download → multipart POST | Download → multipart POST | — |
| Recall | rev-map → `deleteMessage` | — | rev-map → `dc_message_delete` | — | — (no webhook for DC deletes) |
| Location/Contact/Dice/Poll | Text label | Text label | Text label | Text label | — |

### QQ Bot source (webhook events)

Official webhook events carry media **only** as `attachments` (`url` + `content_type`, no local path,
no segments), so each item is downloaded once and re-uploaded through the existing multipart helpers.
Relay is best-effort: a failed item is logged and the caption still goes out.

| Content type | QQ Bot→TG | QQ Bot→DC |
|--------------|-----------|-----------|
| Text | `sendMessage` + `🅠` | `dc_message_create` + `🅠` |
| `image/*` | Download → `sendPhoto` | Download → multipart POST |
| `video/*` | Download → `sendVideo` | Download → multipart POST |
| `voice*` / `audio/*` | Prefer `voice_wav_url` (SILK is unplayable) → `sendVoice` | Download → multipart POST |
| Other files | Download → `sendDocument` | Download → multipart POST |

Caption format: `<label> <filename> (<size>)`; label is one of 图片 / 视频 / 语音 / 文件.

## Configuration

**1. Configure mappings** in `etc/sync.conf`:

```
qq/group/123456=telegram/-100111            # QQ group → TG group
qq/group/123456=telegram/-100111/16553      # QQ group → TG forum topic
telegram/-100111=qq/group/123456            # TG group → QQ group
qq/group/123456=discord/ch123456            # QQ group → DC channel
discord/ch123456=qq/group/123456            # DC channel → QQ (daily batch)
qqbot/group/<group_openid>=telegram/-100111 # QQ Bot group → TG group
qqbot/group/<group_openid>=discord/ch123456 # QQ Bot group → DC channel
telegram/-100111=qqbot/group/<group_openid> # TG → QQ Bot group
discord/ch123456=qqbot/channel/<channel_id> # DC → QQ Bot channel
```

QQ Bot targets accept `qqbot/group/<group_openid>`, `qqbot/private/<user_openid>` and
`qqbot/channel/<channel_id>`.

Supports any number of mappings. Each line is read independently — one source message can be forwarded to multiple targets, and multiple sources can feed the same target. No practical limit on line count.

```
qq/group/A=telegram/X           # QQ group A → TG
qq/group/B=telegram/X           # 2 QQ groups → same TG
telegram/X=qq/group/A           # TG → QQ group A
telegram/X=qq/group/B           # same TG → 2 QQ groups
```

**2. Enable** with the `*` rule in `etc/rules`:

```
*|../plugin/sync/handler.sh|sync_handler
```

## Limitations

- Discord→QQ/TG messages are polled daily (Discord message events require Gateway/WebSocket)
- DC→QQ/TG recall is not possible (Discord webhooks don't include deletion events)
- TG→QQ recall is not possible (TG webhooks don't include deletion events)
- TG Bot API `getFile` has a **20MB** file size limit
- QQ Bot inbound media only arrives as `attachments[]` URLs on webhook events; the file is downloaded
  once and re-uploaded, so very large attachments are bounded by the QQ Bot upload API
- QQ Bot recall maps back through `msg-map-rev` (`qqbot <gid|oid> <msg id>`), one entry per source message

QQ↔Telegram fully bidirectional. Discord integrated for all three platforms with real-time outbound (QQ/TG→DC) and daily batch inbound (DC→QQ/TG). QQ recall syncs to both TG and DC. QQ Bot (official webhook bot) is a fourth source/target: text plus attachments to TG and DC, and DC→QQ Bot text outbound with rev-map for recalls.
