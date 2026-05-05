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
| →DC | `👾 用户: 消息` | (not implemented) |

## Content Type Handling

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

## Configuration

**1. Configure mappings** in `etc/sync.conf`:

```
qq/group/123456=telegram/-100111            # QQ group → TG group
qq/group/123456=telegram/-100111/16553      # QQ group → TG forum topic
telegram/-100111=qq/group/123456            # TG group → QQ group
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

- Discord→QQ/TG requires Gateway (WebSocket), not feasible in pure shell
- TG→QQ recall is not possible (TG webhooks don't include deletion events)
- TG Bot API `getFile` has a **20MB** file size limit — files larger than 20MB (e.g., long videos) can be received via webhook but cannot be downloaded for forwarding. These are skipped with a log message.

QQ↔Telegram is fully bidirectional — text, image, file, voice, video, sticker, reaction, recall (QQ→TG).
