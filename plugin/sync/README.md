# Cross-Platform Sync

> [中文](README.zh.md)

Messages from one platform auto-forward to the others. Images and files are downloaded locally then re-uploaded (not URL pass-through), preserving content integrity end-to-end.

## Architecture

```
plugin/sync/
├── common.sh      — Shared utilities, adapter imports
├── from_qq.sh     — QQ source → TG/DC forwarders
├── from_tg.sh     — TG source → QQ/DC forwarders
├── from_dc.sh     — DC source → QQ/TG forwarders (stub)
└── handler.sh     — sync_handler main router
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

## Configuration

**1. Configure mappings** in `etc/sync.conf`:

```
qq/group/123456=telegram/-100111            # QQ group → TG group
qq/group/123456=telegram/-100111/16553      # QQ group → TG forum topic
telegram/-100111=qq/group/123456            # TG group → QQ group
qq/group/123456=discord/ch123456            # QQ group → DC channel
discord/ch123456=qq/group/123456            # DC channel → QQ (daily batch)
```

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

QQ↔Telegram fully bidirectional. Discord integrated for all three platforms with real-time outbound (QQ/TG→DC) and daily batch inbound (DC→QQ/TG). QQ recall syncs to both TG and DC.
