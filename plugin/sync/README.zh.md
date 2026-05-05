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
| →DC | `👾 用户: 消息` | (未实现) |

## 内容类型处理

| 类型 | QQ→TG | TG→QQ |
|------|-------|-------|
| 文字 | `sendMessage` + 🐧 前缀 | QQ text segment + ✈️ 前缀 |
| 图片 | 下载 → GIF 检测 → `sendAnimation`/`sendPhoto` | 下载 → image segment (`file://` URI) |
| 文件 | 下载 → multipart `sendDocument` | 下载 → `upload_group_file` |
| 贴纸 | — | 静态 WEBP → 图片；视频 WEBM/TGS → 文件 |
| 表情反应 | — | `message_reaction` → msg-map 查映射 → `send_group_message_reaction` |
| GIF/动画 | — | 下载 → `upload_group_file`（TG 转为 MP4） |
| 语音 | 下载 `temp_url` → multipart `sendVoice` | 下载 → QQ record segment |
| 视频 | 下载 `temp_url` → multipart `sendVideo` | 下载 → QQ video segment |
| 回复 | 文字中包含上下文 | 文字中包含上下文 |
| 转发 | `[转发]` 前缀 | `[转发]` 前缀 |
| 撤回 | `message_recall` → 反向映射 → `deleteMessage` | —（TG webhook 不含删除事件） |
| 位置/联系人/骰子/投票 | 文字标签 | 文字标签 |

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

- Discord→QQ/TG 需要 Gateway (WebSocket)，纯 shell 无法实现
- TG→QQ 撤回不可行（TG webhook 不含删除事件）
- TG Bot API `getFile` 有 **20MB** 文件大小限制 —— 超过 20MB 的文件（如长视频）可通过 webhook 接收但无法下载转发，会被跳过并记录日志

QQ↔Telegram 完全双向同步 —— 文字、图片、文件、语音、视频、贴纸、表情反应、撤回（QQ→TG）。
