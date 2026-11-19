# 跨平台消息同步

> [English](README.md)

一个平台的消息自动转发到其他平台。图片和文件均先下载到本地再重新上传（非 URL 透传），确保内容端到端完整送达。

## 架构

```
plugin/sync/
├── common.sh       — 共享工具 + 适配器导入
├── from_qq.sh      — QQ 源 → TG/DC 转发
├── from_tg.sh      — TG 源 → QQ/DC 转发
├── from_qqbot.sh   — QQ Bot 源 → TG/DC 转发（媒体取自 attachments[]）
├── from_dc.sh      — DC 源 → QQ/TG/QQBot 转发
├── dc-sync.sh      — DC 每日批量拉取（cron）
└── handler.sh      — sync_handler 主路由
```

## 方向与防循环

| 方向 | 格式 | 防循环 |
|------|------|--------|
| QQ→TG | `🐧 用户: 消息` | emoji 前缀 + bot 发送者 ID |
| TG→QQ | `✈️ 用户: 消息` | emoji 前缀 + bot 发送者 ID |
| QQ→DC | `🐧 用户: 消息` | emoji 前缀 + bot 发送者 ID |
| TG→DC | `✈️ 用户: 消息` | emoji 前缀 + bot 发送者 ID |
| DC→QQ | `👾 用户: 消息` | 发送者 ID (`DC_BOT_ID`) |
| DC→TG | `👾 用户: 消息` | 发送者 ID (`DC_BOT_ID`) |
| QQ Bot→TG | `🅠 用户: 消息` | emoji 前缀（QQ Bot 无数字发送者 ID） |
| QQ Bot→DC | `🅠 用户: 消息` | emoji 前缀 |
| DC→QQ Bot | `👾 用户: 消息` | 发送者 ID (`DC_BOT_ID`) |

QQ Bot（`qqbot`）是与 QQ（Milky）完全不同的适配器：ID 是 `openid` / `group_openid` 而非数字 QQ 号，
传输方式是 webhook 而非本地 HTTP API。转发图标为 `🅠`，因此 `handler.sh` 的防循环判断与 `🐧` 相互独立。

## 内容类型处理

| 类型 | QQ→TG | TG→QQ | QQ→DC | TG→DC | DC→QQ/TG |
|------|-------|-------|-------|-------|----------|
| 文字 | `sendMessage` + 🐧 | QQ text segment + ✈️ | `dc_message_create` + 🐧 | `dc_message_create` + ✈️ | 文字 + 👾（每日批量） |
| 图片 | 下载 → GIF 检测 → `sendAnimation`/`sendPhoto` | 下载 → image segment | 下载 → multipart POST | 下载 → multipart POST | — |
| 文件 | 下载 → multipart `sendDocument` | 下载 → `upload_group_file` | 下载 → multipart POST | 下载 → multipart POST | — |
| 贴纸 | — | 静态 WEBP → 图片；视频 WEBM/TGS → 文件 | — | 静态 → 图片；视频 → 文件 | — |
| 表情反应 | — | msg-map 查映射 → `send_group_message_reaction` | — | — | — |
| GIF | — | 下载 → `upload_group_file`（MP4） | — | 下载 → multipart POST | — |
| 语音 | 下载 → multipart `sendVoice` | 下载 → QQ record | 下载 → multipart POST | 下载 → multipart POST | — |
| 视频 | 下载 → multipart `sendVideo` | 下载 → QQ video | 下载 → multipart POST | 下载 → multipart POST | — |
| 撤回 | rev-map → `deleteMessage` | — | rev-map → `dc_message_delete` | — | —（DC 删除无 webhook 通知） |
| 位置/联系人/骰子/投票 | 文字标签 | 文字标签 | 文字标签 | 文字标签 | — |

### TG 源 → QQ Bot（官方）

此前 `qqbot` 目标只发文字，TG 的贴纸/图片到 QQ 只剩一行 `[贴纸: ⭐]` 标签，媒体本体没过去。
现在 `handler.sh` 在 qqbot 目标发完文字后调用 `_sync_tg_media_to_qqbot()`：先 `tg_getFile` 下载，
再按 `file_type` 以 base64 `file_data` 上传。超过 `QQBOT_FILE_DATA_MAX`（5 MB 硬上限）时记日志跳过，
**不降级成"文件"**——降级只会把"没发出去"伪装成"发成了文件"。

| TG 内容 | `file_type` | 文件名 | QQ 侧表现 |
| --- | --- | --- | --- |
| 静态贴纸（`is_video=false`） | 1 图片 | `sticker.webp` | 内联图片 |
| 视频贴纸（`is_video=true`） | 2 视频 | `sticker.webm` | 可播放视频 |
| 动态贴纸 TGS（`is_animated=true`） | 4 文件 | `sticker.tgs` | 文件（平台无法内联渲染 Lottie） |
| 图片 `photo[]`（取最大档） | 1 图片 | `photo.jpg` | 内联图片 |
| 动图 `animation` | 1 / 2 | `animation.gif` / `animation.mp4` | 按 `mime_type` 决定 |
| 视频 / 语音 / 音频 / 文档 | 2 / 3 / 3 / 4 | `video.mp4` / `voice.ogg` / 原名 / `document.bin` | 对应消息类型 |

不走 URL 直传：TG 下载 URL 里带 bot token，且只认 CF Worker 的 `X-Ayu-Token` 头，QQ 侧拉不到。
`channel/*` 目标暂不支持媒体（官方 API 无对应上传接口），`log_debug` 记录后跳过。

### QQ Bot 源（webhook 事件）

官方 webhook 事件的媒体**只**以 `attachments`（`url` + `content_type`，无本地路径、无 segment）形式下发，
因此每条附件先下载一次，再走现成的 multipart helper 重传。转发是尽力而为：单条失败只记日志，文字仍发出。

| 内容类型 | QQ Bot→TG | QQ Bot→DC |
| --- | --- | --- |
| 文字 | `sendMessage` + `🅠` | `dc_message_create` + `🅠` |
| `image/*` | 下载 → `sendPhoto` | 下载 → multipart POST |
| `video/*` | 下载 → `sendVideo` | 下载 → multipart POST |
| `voice*` / `audio/*` | 优先 `voice_wav_url`（SILK 无法播放）→ `sendVoice` | 下载 → multipart POST |
| 其他文件 | 下载 → `sendDocument` | 下载 → multipart POST |

说明文字格式：`<标签> <文件名> (<大小>)`；标签为 图片 / 视频 / 语音 / 文件。

## 配置

**1. 配置映射** `etc/sync.conf`：

```
qq/group/123456=telegram/-100111            # QQ 群 → TG 群
qq/group/123456=telegram/-100111/16553      # QQ 群 → TG 论坛话题
telegram/-100111=qq/group/123456            # TG 群 → QQ 群
qqbot/group/<group_openid>=telegram/-100111 # QQ Bot 群 → TG 群
qqbot/group/<group_openid>=discord/ch123456 # QQ Bot 群 → DC 频道
telegram/-100111=qqbot/group/<group_openid> # TG → QQ Bot 群
discord/ch123456=qqbot/channel/<channel_id> # DC → QQ Bot 频道
```

QQ Bot 目标支持 `qqbot/group/<group_openid>`、`qqbot/private/<user_openid>`、`qqbot/channel/<channel_id>` 三种。

支持任意多行映射。每行独立解析——一条源消息可转发到多个目标，多个源也能指向同一个目标，行数无限制。

```
qq/group/A=telegram/X           # QQ 群 A → TG
qq/group/B=telegram/X           # 2 个 QQ 群 → 同一个 TG
telegram/X=qq/group/A           # TG → QQ 群 A
telegram/X=qq/group/B           # 同一个 TG → 2 个 QQ 群
```

**2. 启用**: `etc/rules` 中的 `*` 规则：

```
*|../plugin/sync/handler.sh|sync_handler
```

## 限制

- Discord→QQ/TG 消息为每日批量拉取（Discord 消息事件需要 Gateway/WebSocket）
- DC→QQ/TG 撤回不可行（Discord webhook 不含删除事件）
- TG→QQ 撤回不可行（TG webhook 不含删除事件）
- TG Bot API `getFile` 有 **20MB** 文件大小限制
- QQ Bot 入站媒体只以 `attachments[]` URL 下发，需先下载再重传，超大附件受 QQ Bot 上传 API 限制
- QQ Bot 撤回归档到 `msg-map-rev`（`qqbot <gid|oid> <msg id>`），一条源消息一条记录

QQ↔Telegram 完全双向同步。Discord 已接入三端：实时出站（QQ/TG→DC）+ 每日批量入站（DC→QQ/TG）。QQ 撤回顾及 TG 和 DC 双端。QQ Bot（官方 webhook 机器人）是第四个源/目标：文字与附件转发到 TG / DC，DC→QQ Bot 文字出站并带撤回映射。
