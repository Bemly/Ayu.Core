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
[<platform>:]<pattern>|<script>|<func>
```

脚本路径相对于 `adapter/`，引用 plugin 用 `../plugin/...`。

```
qqbot:/ping|qqbot/handler.sh|qqbot_handler_ping    # 只在 qqbot 平台命中
qqbot:/echo|qqbot/handler.sh|qqbot_handler_echo
qqbot:/info|qqbot/handler.sh|qqbot_handler_info
qqbot:/recall|qqbot/handler.sh|qqbot_handler_recall
/ping|qq/handler.sh|handler_ping                   # 无前缀 → 所有平台都命中
/echo|qq/handler.sh|handler_echo
*|../plugin/sync/handler.sh|sync_handler           # → plugin/sync/handler.sh
```

### 平台前缀

`<platform>:` 可省略，取值 `qq:` / `qqbot:` / `telegram:` / `discord:`：

| 写法 | 生效范围 |
| --- | --- |
| `qqbot:/ping` | 仅 `qqbot` 事件 |
| `qq:/ping` | 仅 QQ (Milky) 事件 |
| `/ping` | 全部平台（历史行为，向后兼容） |

不带前缀的规则会被**所有**适配器命中。给某个平台写专属命令时务必加前缀，否则 qqbot 的
`GROUP_AT_MESSAGE_CREATE`、QQ 的群消息会抢到同一条规则。前缀只做平台过滤，glob 匹配仍在剩余部分进行。

### Handler 函数签名
```sh
handler_func <platform> <event> <user_id> <text> <raw_json>
```

- `platform`: `qq` / `qqbot` / `telegram` / `discord`
- `event`: `message` / `reaction` / `message_recall` / `group_nudge` 等；qqbot 传的是原始事件名
  （`GROUP_AT_MESSAGE_CREATE`、`C2C_MESSAGE_CREATE`、`AT_MESSAGE_CREATE`、`INTERACTION_CREATE`、
  `GROUP_ADD_ROBOT` …）
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
qqbot/group/<group_openid>=telegram/-100111   # QQ Bot 群 → TG
qqbot/group/<group_openid>=discord/ch123456   # QQ Bot 群 → DC
telegram/-100111=qqbot/group/<group_openid>   # TG → QQ Bot 群
telegram/-100111=qqbot/private/<user_openid>  # TG → QQ Bot 单聊
discord/ch123456=qqbot/channel/<channel_id>   # DC → QQ Bot 频道
```

支持多对多。行数无限制，每条源消息可转发到多个目标。

qqbot 的平台名是 `qqbot`，ID 段是 `openid` / `group_openid`（不是 QQ 号）；目标形式支持
`group` / `private` / `channel` 三种，见 `plugin/sync/README.md`。

## config.sh

```sh
QQ_HOST="host.docker.internal"
QQ_PORT="616"
QQ_TOKEN=""                    # LLOneBot (Milky) API token

TG_TOKEN=""                    # @BotFather 获取
TG_API_HOST="api.telegram.org"
TG_API_SECRET=""               # CF Worker X-Ayu-Token

DC_TOKEN=""                    # Discord Bot token
DC_BOT_ID=""                   # Bot 自己的 Discord user ID（防循环）
DC_CDN_PROXY=""                # cdn.discordapp.com 不可达时的代理

# --- QQ Bot 官方 OpenAPI v2（仅 webhook）---
QQBOT_APP_ID=""                # q.qq.com AppID
QQBOT_APP_SECRET=""            # AppSecret，同时是回调 Ed25519 的种子
QQBOT_API_BASE="https://api.bot.qq.com"
QQBOT_VERIFY_SIG="auto"        # auto | 1 失败即拒 | 0 关闭
QQBOT_WEBHOOK_TOKEN=""         # URL 安全 token，优先于 WEBHOOK_SECRET
QQBOT_BOT_OPENID=""            # bot 自身 openid（全量流下命令需 @ 它）
QQBOT_ADMINS=""                # 允许查看历史的 openid，空格分隔
QQBOT_HIST_KEEP="50"           # 单会话历史保留条数
QQBOT_HIST_SHOW="5"            # 「@bot 历史」返回条数

BOT_PORT="6160"
WEBHOOK_SECRET=""              # 设后 ?token=xxx 必填
_LOG_LEVEL="1"                 # 0=trace 1=info 2=warn 3=err
MAINT_STATE_KEEP_DAYS="30"     # var/state 修剪：保留天数
MAINT_STATE_KEEP_ITEMS="5000"  # 单会话保留条数（保底 200）
MAINT_STATE_DRY="0"            # 1 = 只统计不删除
```

### 环境分层

所有值可通过环境变量 `ENV_VAR=value` 覆盖。`config.sh` 逐键提供空默认值，环境覆盖文件后加载、逐键覆盖：

| 文件 | 何时加载 | 是否入库 |
| --- | --- | --- |
| `config.sh` | 总是 | 是（空模板） |
| `config.dev.sh` | `AYU_ENV=dev` | 否 |
| `config.local.sh` | `AYU_ENV=local` | 否 |
| `config.prod.sh` | `AYU_ENV=prod` | 否（gitignored，生产真值） |

`AYU_ENV` 未设时按宿主特征推断（NAS 路径 → `prod`）。从 `config.prod.example.sh` 复制起步；
**生产 `config.sh` 与 `config.prod.sh` 永不用仓库版本覆盖**。

QQ Bot 各键说明：

| 键 | 说明 |
| --- | --- |
| `QQBOT_APP_ID` / `QQBOT_APP_SECRET` | 平台后台的 AppID / AppSecret（后者兼作验签种子） |
| `QQBOT_API_BASE` | API 根，可指向自建代理 |
| `QQBOT_VERIFY_SIG` | `auto` / `1` / `0`，见 `SECURITY.md` |
| `QQBOT_WEBHOOK_TOKEN` | `/qqbot` 专用 token；`WEBHOOK_SECRET` 含 `#` `<` `;` 时必用 |
| `QQBOT_BOT_OPENID` | bot 自身 openid；设置后全量流消息必须 @ 它才当命令 |
| `QQBOT_ADMINS` | 允许 `@bot @某人 昵称` 绑定的 openid，支持 ≥7 位前缀匹配 |
| `QQBOT_HIST_KEEP` / `QQBOT_HIST_SHOW` | 历史留存条数 / 查询返回条数 |

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

### QQ Bot（官方 OpenAPI v2）

| 函数 | 参数 | 返回 |
|------|------|------|
| `qqbot_message_send_group` | `group_openid text` | API 响应 JSON |
| `qqbot_message_send_c2c` | `user_openid text` | API 响应 JSON |
| `qqbot_message_send_channel` | `channel_id text` | API 响应 JSON |
| `qqbot_message_recall_group` | `group_openid msg_id` | 无 |
| `qqbot_file_upload_group` | `group_openid file_path` | API 响应 JSON |
| `qqbot_body_text` | `text` | 文本 body JSON |
| `qqbot_seg` | `str` | URL 段编码后的值 |
| `_qqbot_api` | `method path body tag` | API 响应（内部，带 token 刷新） |

共 125 个函数，详见 `adapter/qqbot/README.md`

### Telegram

| 函数 | 参数 | 返回 |
|------|------|------|
| `tg_sendMessage` | `chat_id text [parse_mode]` | API 响应 JSON |
| `tg_deleteMessage` | `chat_id message_id` | API 响应 JSON |
| `tg_getFile` | `file_id` | `{file_path:...}` |
| `_tg_api` | `method json_body [tag]` | API 响应（temp file） |
| `tg_sendPhoto` | `chat_id photo [caption] [thread]` | API 响应 JSON |

共 175 个函数，详见 `adapter/telegram/README.md`

### Discord

| 函数 | 参数 | 返回 |
|------|------|------|
| `dc_message_create` | `channel_id json_body` | API 响应 JSON |
| `dc_message_list` | `channel_id` | 消息数组 JSON |
| `dc_message_edit` | `channel_id msg_id json_body` | API 响应 JSON |
| `dc_message_delete` | `channel_id msg_id` | 无 |
| `dc_webhook_execute` | `webhook_id token text [username]` | 无 |

共 143 个函数，详见 `adapter/discord/README.md`

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
