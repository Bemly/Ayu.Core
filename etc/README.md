# etc/ — 框架配置与插件注册

Ayu.Core 的配置和插件接入层。所有文件通过 `$_HB/etc/` 引用。

## 注册文件一览

| 文件 | 用途 | 格式 | 消费者 |
|------|------|------|--------|
| [rules](#rules) | 消息路由（实时） | `<pattern>\|<script>\|<func>` | `lib/dispatch.sh` |
| [crontab](#crontab) | 定时任务 | `<cron expr>\|<script>\|<func>` | `cgi-bin/start.sh` → `crond` |
| [sync.conf](#syncconf) | 跨平台同步映射 | `<src>=<tgt>` | `plugin/sync/handler.sh`, `plugin/sync/dc-sync.sh` |
| [config.sh](#configsh) | 全局配置 | shell 变量（env 可覆盖） | 全局 |
| httpd.conf | busybox httpd 配置 | httpd 指令 | `httpd` |

`#` 开头为注释，空行跳过。

## rules

### 格式
```
<pattern>|<script>|<func>
```

脚本路径相对于 `adapter/`，引用 plugin 用 `../plugin/...`。

```
/ping|qq/handler.sh|handler_ping              # → adapter/qq/handler.sh
/echo|qq/handler.sh|handler_echo              # → adapter/qq/handler.sh
*|../plugin/sync/handler.sh|sync_handler      # → plugin/sync/handler.sh
```

### Handler 函数签名
```sh
handler_func <platform> <event> <user_id> <text> <raw_json>
```

- `platform`: `qq` / `telegram` / `discord`
- `event`: `message` / `reaction` / `message_recall` / `group_nudge` 等
- `user_id`: 发送者 ID
- `text`: 解码后的消息文本
- `raw_json`: 平台原始 JSON

匹配从上到下，首中即停。精确命令放前面，`*` 兜底放最后。

## crontab

### 格式
```
<分 时 日 月 周>|<script>|<func>
```

脚本路径相对于 `adapter/`，和 rules 同约定。

```
0 0 * * *|../plugin/sync/dc-sync.sh|dc_batch_run  # DC 每日同步（UTC 0 点）
```

### Handler 函数签名
```sh
handler_func    # 无参数，函数内部自行处理（含 bootstrap + source）
```

`start.sh` 启动时读取此文件，生成 `/var/spool/cron/crontabs/root` 供 `crond` 执行。

## sync.conf

### 格式
```
<src_platform/id>=<tgt_platform/id>
```

```
qq/group/123456=telegram/-100111              # QQ 群 → TG 群
telegram/-100111=qq/group/123456              # TG 群 → QQ 群
qq/group/123456=discord/ch123456              # QQ 群 → DC 频道
discord/ch123456=qq/group/123456              # DC 频道 → QQ（每日批量）
telegram/-100111=telegram/-100222/16553       # TG → TG 话题
```

支持多对多。行数无限制，每条源消息可转发到多个目标。

## config.sh

```sh
QQ_HOST="host.docker.internal"
QQ_PORT="616"
QQ_TOKEN=""                    # Lagrange API token

TG_TOKEN=""                    # @BotFather 获取
TG_API_HOST="api.telegram.org"
TG_API_SECRET=""               # CF Worker X-Ayu-Token

DC_TOKEN=""                    # Discord Bot token
DC_BOT_ID=""                   # Bot 自己的 Discord user ID（防循环）

BOT_PORT="6160"
WEBHOOK_SECRET=""              # 设后 ?token=xxx 必填
_LOG_LEVEL="1"                 # 0=trace 1=info 2=warn 3=err
```

所有值可通过环境变量 `ENV_VAR=value` 覆盖。生产密钥放 `etc/config.nas.sh`（gitignored）。

## 可用适配器 API

### QQ

| 函数 | 参数 | 返回 |
|------|------|------|
| `qq_message_send_group` | `group_id segments_json` | API 响应 JSON |
| `qq_message_send_private` | `user_id segments_json` | API 响应 JSON |
| `qq_text_segments` | `text` | segment JSON 数组 |
| `qq_group_send_reaction` | `gid seq code is_add` | API 响应 JSON |
| `qq_file_get_download_url` | `gid fid` | `{download_url:...}` |
| `qq_file_upload_group` | `gid file_path` | API 响应 JSON |

详见 `adapter/qq/README.md`

### Telegram

| 函数 | 参数 | 返回 |
|------|------|------|
| `tg_sendMessage` | `chat_id text [parse_mode]` | API 响应 JSON |
| `tg_deleteMessage` | `chat_id message_id` | API 响应 JSON |
| `tg_getFile` | `file_id` | `{file_path:...}` |
| `_tg_api` | `method json_body [tag]` | API 响应（temp file） |
| `tg_sendPhoto` | `chat_id photo [caption] [thread]` | API 响应 JSON |

共 169 个函数，详见 `adapter/telegram/README.md`

### Discord

| 函数 | 参数 | 返回 |
|------|------|------|
| `dc_message_create` | `channel_id json_body` | API 响应 JSON |
| `dc_message_list` | `channel_id` | 消息数组 JSON |
| `dc_message_edit` | `channel_id msg_id json_body` | API 响应 JSON |
| `dc_message_delete` | `channel_id msg_id` | 无 |
| `dc_webhook_execute` | `webhook_id token text [username]` | 无 |

共 135 个函数，详见 `adapter/discord/README.md`

## 可用库函数

| 函数 | 文件 | 用途 |
|------|------|------|
| `json_get` `<json> <key>` | `lib/core.sh` | JSON 值提取（返回 NOTFOUND 或值） |
| `json_obj` `<k1> <v1> ...` | `lib/core.sh` | 构造 `{"k":"v",...}` |
| `http_get` `<url> [header...]` | `lib/http.sh` | HTTP GET → stdout |
| `http_post` `<url> <body> [header...]` | `lib/http.sh` | HTTP POST → stdout |
| `http_get_file` `<url> <path> [header...]` | `lib/http.sh` | 下载到文件（二进制安全） |
| `http_post_file` `<url> <file> [header...]` | `lib/http.sh` | 上传文件（二进制安全） |
| `log_info` `log_debug` `log_warn` `log_err` | `lib/log.sh` | 分级日志（stderr） |
| `url_encode` `<str>` | `lib/url.sh` | URL 编码 |
| `url_decode` `<str>` | `lib/url.sh` | URL 解码 |
| `utf8_decode` `<str>` | `lib/url.sh` | `\uXXXX` → UTF-8 |
