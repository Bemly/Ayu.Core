# 跨平台消息同步

> [English](README.md)

一个平台的消息自动转发到其他平台。图片和文件均先下载到本地再重新上传（非 URL 透传），确保内容端到端完整送达。

## 架构

```
plugin/sync/
├── common.sh      — 共享工具 + 适配器导入
├── from_qq.sh     — QQ 源 → TG/DC 转发
├── from_tg.sh     — TG 源 → QQ/DC 转发
├── from_dc.sh     — DC 源 → QQ/TG 转发（stub）
└── handler.sh     — sync_handler 主路由
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

## 配置

**1. 配置映射** `etc/sync.conf`：

```
qq/group/123456=telegram/-100111            # QQ 群 → TG 群
qq/group/123456=telegram/-100111/16553      # QQ 群 → TG 论坛话题
telegram/-100111=qq/group/123456            # TG 群 → QQ 群
```

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

QQ↔Telegram 完全双向同步。Discord 已接入三端：实时出站（QQ/TG→DC）+ 每日批量入站（DC→QQ/TG）。QQ 撤回顾及 TG 和 DC 双端。
