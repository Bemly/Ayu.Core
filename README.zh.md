![# Ayu.Core](https://socialify.git.ci/Bemly/Ayu.Core/image?custom_description=%E7%94%B1+%E5%BD%A9%E6%A2%A6%E6%A0%B8%E5%BF%83+%E9%A9%B1%E5%8A%A8%E7%9A%84%E7%BA%AF+Shell+%E6%9C%BA%E5%99%A8%E4%BA%BA%E6%A1%86%E6%9E%B6&description=1&font=KoHo&logo=https%3A%2F%2Fraw.githubusercontent.com%2FBemly%2FAyu.Core%2Frefs%2Fheads%2Fmain%2Fwebui%2Flogo.jpg&name=1&pattern=Formal+Invitation&theme=Light)

[![test](https://github.com/Bemly/Ayu.Core/actions/workflows/test.yml/badge.svg)](https://github.com/Bemly/Ayu.Core/actions/workflows/test.yml)

纯 shell SNS Bot 框架。运行在 busybox:musl 容器中，hush + httpd CGI + 原生 TLS 传输 + [hush-json](https://github.com/Bemly/hush-json) + [hush-ed25519](https://github.com/Bemly/hush-ed25519)。

> [English](README.md)

## 适配器覆盖

| 平台 | 端点 | 方法 | README |
|------|------|------|--------|
| QQ (Milky / LLOneBot) | 29/29 | 39 | [adapter/qq/README.md](adapter/qq/README.md) |
| QQ Bot 官方 OpenAPI v2（webhook） | 46 个 HTTP API / 22 类事件（代码实现 20 个分支） | 125 | [adapter/qqbot/README.md](adapter/qqbot/README.md) |
| Telegram Bot API | 169/169 | 175 | [adapter/telegram/README.md](adapter/telegram/README.md) |
| Discord REST API v10 | 185 bot API | 143 | [adapter/discord/README.md](adapter/discord/README.md) |

方法数为各适配器目录 `grep -cE '^[a-z_]+\(\)'` 的统计结果，不是官方端点数量。协议细节见
[adapter/qq/README.md](adapter/qq/README.md)（370 行，Milky API）与
[adapter/qqbot/README.md](adapter/qqbot/README.md)（10 章，官方 OpenAPI v2 + webhook）。

### QQ Bot 速览

| 项 | 值 |
| --- | --- |
| 回调路径 | `/cgi-bin/router.sh/qqbot`（整段匹配，`/qqbotxxx` 会被拒；与 `/qq` 互不影响） |
| 传输 | HTTPS API + webhook 回调（**不实现** WebSocket 网关） |
| 出站鉴权 | `Authorization: QQBot <access_token>`，`POST /app/getAppAccessToken` 缓存并提前刷新 |
| 入站鉴权 | `?token=<WEBHOOK_SECRET>`（或 `QQBOT_WEBHOOK_TOKEN`）**加上** Ed25519 `X-Signature-Ed25519` / `X-Signature-Timestamp` |
| URL 校验 | `op=13` → 回 `plain_token` + `signature` |
| 事件 ACK | `op=0` → `{"op":12,"d":{}}`（不 ACK 平台会重试） |
| ID 体系 | 只有 `openid` / `group_openid`，没有任何 QQ 号 |
| 代码 | `adapter/qqbot/` 9 文件 / 125 函数 |
| 测试 | 400 条里有 130 条覆盖该适配器 |

`QQBOT_VERIFY_SIG` 控制验签模式：`auto`（有密钥和 Ed25519 实现时自动开启）、`1`（失败即拒，拒收未签名回调）、`0`（关闭，不推荐）。

## 架构

```
请求流:
  SNS平台 → webhook → httpd CGI → router.sh → adapter → dispatch.sh → handler → adapter → nc+ssl_client → SNS平台

Ayu.Core/
├── cgi-bin/                # CGI 脚本 (busybox httpd 写死 /cgi-bin/)
│   ├── start.sh            # 启动 httpd + crond
│   └── router.sh           # CGI 入口 (平台路由 + token 鉴权)
├── lib/
│   ├── core.sh             # _ERROR 链, die(), hush-json + hush-url 引导
│   ├── http.sh             # HTTP/HTTPS via nc + ssl_client (GET/POST, 重试, chunked 解码)
│   ├── dispatch.sh         # 消息路由 + 插件接口 (etc/rules)
│   ├── log.sh              # 分级日志 (debug/info/warn/err)
│   └── url.sh              # url_encode/decode + utf8_decode (\uXXXX→UTF-8)
├── adapter/                # 平台适配器
│   ├── qq/                 # QQ (Milky) — 7 文件, 39 个函数, 15 种 segment, 8 种事件
│   ├── qqbot/              # QQ Bot 官方 OpenAPI v2 — 9 文件, 125 个函数, webhook + Ed25519
│   ├── telegram/           # Telegram — 17 文件, 175 个函数, 20 种 Update, 18 种内容类型
│   └── discord/            # Discord — 19 文件, 143 个函数 (REST + webhook)
├── plugin/                 # 业务插件
│   └── sync/               # 跨平台同步 (QQ/QQBot/TG/DC) + dc-sync.sh (crond 定时入口)
├── webui/                  # 面板（原生 HTML/CSS/JS，数据来自 cgi-bin/api.sh）
├── etc/                    # config, rules, crontab, sync.conf, README
├── hush-json/              # submodule — POSIX sh 实现的 JSON
├── hush-ed25519/           # submodule — shell + busybox awk 实现的 Ed25519 签名/验签
└── test/                   # 400 tests, 0 failures (mock_http, 无需 API key)
```

## 快速开始

```sh
# 构建
docker build -t ayu-core .

# 启动
docker run -d -p 6160:6160 --name ayu ayu-core

# QQ webhook
curl -X POST http://localhost:6160/cgi-bin/router.sh/qq \
  -H 'Content-Type: application/json' \
  -d '{"event_type":"message_receive","data":{"sender_id":111,"message_scene":"friend","segments":[{"type":"text","data":{"text":"/ping"}}]}}'
# → {"status":"ok"}

# Telegram webhook
curl -X POST http://localhost:6160/cgi-bin/router.sh/telegram \
  -H 'Content-Type: application/json' \
  -d '{"update_id":1,"message":{"message_id":1,"from":{"id":111},"chat":{"id":222},"text":"/ping"}}'
# → {"status":"ok"}

# QQ Bot webhook — URL 校验 (op=13)
curl -X POST 'http://localhost:6160/cgi-bin/router.sh/qqbot?token=<WEBHOOK_SECRET>' \
  -H 'Content-Type: application/json' \
  -d '{"op":13,"d":{"plain_token":"Arq0D5A61EgUu4OxUvOp","event_ts":"1725442341"}}'
# → {"plain_token":"...","signature":"..."}

# QQ Bot webhook — 事件 ACK (op=0，需带合法 Ed25519 签名)
curl -X POST 'http://localhost:6160/cgi-bin/router.sh/qqbot?token=<WEBHOOK_SECRET>' \
  -H 'Content-Type: application/json' \
  -H 'X-Signature-Ed25519: <sig>' -H 'X-Signature-Timestamp: <ts>' \
  -d '{"op":0,"t":"GROUP_AT_MESSAGE_CREATE","id":"EVENT_ID","d":{}}'
# → {"op":12,"d":{}}      (签名错 → 401，token 错 → 403)
```

## 配置

```sh
# etc/config.sh — 所有值都可通过环境变量覆盖
QQ_HOST="host.docker.internal"   # bridge 用 host.docker.internal, host 用 127.0.0.1
QQ_PORT="616"
QQ_TOKEN=""                      # 通过环境变量或生产覆盖文件设置

TG_TOKEN=""                      # @BotFather 获取的 Bot token
TG_API_HOST="api.telegram.org"   # 网络受限时用 CF Worker 中转
TG_API_SECRET=""                 # 边缘认证用的 X-Ayu-Token 头部
TG_BOT_ID=""                     # bot 自己的 id（跳过自身，防循环）

DC_TOKEN=""
DC_BOT_ID=""                     # 设后跳过 bot 自己的消息 (防循环)
DC_CDN_PROXY=""                  # cdn.discordapp.com 不可达时的代理

# --- QQ Bot 官方 OpenAPI v2（仅 webhook）---
QQBOT_APP_ID=""                  # q.qq.com 拿到的 AppID
QQBOT_APP_SECRET=""              # AppSecret，同时是回调 Ed25519 的种子
QQBOT_API_BASE="https://api.bot.qq.com"
QQBOT_VERIFY_SIG="auto"          # auto | 1（失败即拒）| 0（关闭）
QQBOT_WEBHOOK_TOKEN=""           # URL 安全 token；WEBHOOK_SECRET 含 # < ; 时改用它
QQBOT_BOT_OPENID=""              # bot 自身 openid；全量流下命令必须 @ 它
QQBOT_ADMINS=""                  # 允许绑定昵称的 openid（空格分隔，支持 ≥7 位前缀）

BOT_PORT="6160"
WEBHOOK_SECRET=""                # 设了就要 ?token=xxx，否则 403
_LOG_LEVEL="1"                   # 0=trace, 1=info, 2=warn, 3=err
```

> 绝不要提交密钥。仓库里的 `etc/config.sh` 只有空默认值模板。
> 生产真值放 `etc/config.prod.sh`（已 gitignore，`AYU_ENV=prod` 时被 source）；
> 从 `etc/config.prod.example.sh` 复制起步。`etc/config.dev.sh` / `etc/config.local.sh` 对应其他环境，
> `etc/config.prod.sh` 逐键覆盖 `etc/config.sh`。

QQ Bot 各键含义：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `QQBOT_APP_ID` | 空 | 机器人 AppID |
| `QQBOT_APP_SECRET` | 空 | AppSecret，同时是回调验签的 Ed25519 种子 |
| `QQBOT_API_BASE` | `https://api.bot.qq.com` | API 根（可指向代理） |
| `QQBOT_VERIFY_SIG` | `auto` | `auto` / `1` 失败即拒 / `0` 关闭 |
| `QQBOT_WEBHOOK_TOKEN` | 空 | `/qqbot` 专用 URL 安全 token，优先于 `WEBHOOK_SECRET` |
| `QQBOT_BOT_OPENID` | 空 | bot 自身 openid；全量流命令需 @ 它 |
| `QQBOT_ADMINS` | `etc/config.sh` 内置一个 | 允许绑定昵称的 openid（空格分隔，支持 ≥7 位前缀） |
| `QQBOT_HIST_KEEP` | `50` | 单会话历史保留条数 |
| `QQBOT_HIST_SHOW` | `5` | `@bot 历史` 返回条数 |

## 平台 API

```sh
. ./lib/core.sh && . ./etc/config.sh

# --- QQ ---
. ./adapter/qq/message.sh
qq_message_send_group "123456" "$(qq_text_segments 'hello')"

# --- Telegram ---
. ./adapter/telegram/message.sh
tg_sendMessage "222" "hello world" "HTML"

# --- Discord ---
. ./adapter/discord/message.sh
dc_message_create "ch1" '{"content":"hello"}'

# --- QQ Bot 官方 ---
. ./adapter/qqbot/message.sh
qqbot_message_send_group "<group_openid>" "$(qqbot_body_text 'hello')"
qqbot_message_send_c2c   "<user_openid>"  "$(qqbot_body_text 'hello')"
qqbot_message_recall_group "<group_openid>" "<msg_id>"
```

## 消息分发

`etc/rules` — 每行一个规则：`<pattern>|<handler_file>|<handler_func>`

```
qqbot:/ping|qqbot/handler.sh|qqbot_handler_ping
qqbot:/echo|qqbot/handler.sh|qqbot_handler_echo
qqbot:/info|qqbot/handler.sh|qqbot_handler_info
qqbot:/recall|qqbot/handler.sh|qqbot_handler_recall
/ping|qq/handler.sh|handler_ping
/echo|qq/handler.sh|handler_echo
/info|qq/handler.sh|handler_info
*|../plugin/sync/handler.sh|sync_handler
```

规则从上到下匹配。命令 handler 先命中，末尾的 `*` 交给同步插件转发。

规则可带可选的 `<platform>:` 前缀（`qq:` `qqbot:` `telegram:` `discord:`），只在该平台生效。
**不带前缀的规则对所有平台生效**（历史行为），所以老的 `/ping|qq/handler.sh|handler_ping` 写法在 qqbot 事件上也会命中。平台专属命令务必加前缀：

| 规则 | 生效平台 | 说明 |
| --- | --- | --- |
| `qqbot:/ping` | 仅 qqbot | 官方机器人内置命令 |
| `qq:/ping` | 仅 QQ (Milky) | Milky 适配器命令 |
| `/ping` | 四个平台全部 | 任何平台都会命中，平台专属 handler 不要这么写 |

## 插件系统

详见 [etc/README.md](etc/README.md) — handler 签名、注册文件、适配器 API 参考。

### 注册文件：

| 文件 | 用途 | 格式 |
|------|------|------|
| `etc/rules` | 消息路由（实时） | `<pattern>\|<script>\|<func>` |
| `etc/crontab` | 定时任务（crond） | `<cron expr>\|<script>\|<func>` |
| `etc/sync.conf` | 跨平台同步映射 | `<src>=<tgt>` |

## 跨平台消息同步

详见 [plugin/sync/README.zh.md](plugin/sync/README.zh.md)

### Discord 同步

| 方向 | 方式 | 支持媒体 | 触发 |
|------|------|---------|------|
| QQ → DC | 实时 | 文字、图片、文件、语音、视频 | Webhook（即时） |
| TG → DC | 实时 | 文字、图片、文件、语音、视频、贴纸、GIF | Webhook（即时） |
| DC → QQ | 每日批量 | 仅文字（媒体规划中） | cron → `dc-sync.sh` |
| DC → TG | 每日批量 | 仅文字（媒体规划中） | cron → `dc-sync.sh` |

**为什么 DC 出站是批量**：Discord 消息事件需要 Gateway (WebSocket)，纯 shell 无法实现。改用 REST API（`GET /channels/{id}/messages`）每日拉取，按当天日期过滤后转发。

**触发 DC 同步**：容器内 `crond` 每天 UTC 0 点通过 `etc/crontab` 执行 `dc_batch_run()`：
```
0 0 * * *|../plugin/sync/dc-sync.sh|dc_batch_run  # DC 每日消息同步
```
其他定时任务在 `etc/crontab` 中添加即可。框架插件 API 详见 `etc/README.md`。

**sync.conf 格式**：
```
qq/group/1081590429=discord/ch123456           # QQ 群 → DC 频道
telegram/-100111=discord/ch123456              # TG 群 → DC 频道
discord/ch123456=qq/group/1081590429           # DC 频道 → QQ（每日批量）
discord/ch123456=telegram/-100111              # DC 频道 → TG（每日批量）
```

**防循环**：`👾` emoji 前缀 + bot 发送者 ID 检测（`DC_BOT_ID` 环境变量）。DC→QQ/TG 转发时跳过 bot 自己的消息。

### QQ Bot（官方）同步

| 方向 | 方式 | 支持媒体 | 触发 |
| --- | --- | --- | --- |
| qqbot → TG | 实时 | 文字、图片、文件、语音（优先转 WAV）、视频 | Webhook（即时） |
| qqbot → DC | 实时 | 文字、图片、文件、语音、视频 | Webhook（即时） |
| TG → qqbot | 实时 | 文字、图片、文件、语音、视频 | `*` 规则 |
| DC → qqbot | 每日批量 | 仅文字 | cron → `dc-sync.sh` |
| qqbot 撤回 → TG/DC | 实时 | rev-map 反查 | Webhook |

官方回调里的媒体只有 `attachments`（`url` + `content_type`，没有本地路径、没有 segment），所以每条附件只下载一次，
再走现成的 multipart helper 重传。整体是尽力而为：单条附件失败只记日志，文字照发。

发送者显示为 `🅠 昵称(qq#ABC1234)` —— 官方 API 不返回昵称，只给按 bot 隔离的 `member_openid`，
需要群管理员用 `@bot @某人 宝宝` 绑定（见下）。

`etc/sync.conf` 的源与目标写法：

```
qqbot/group/<group_openid>=telegram/-100111      # qqbot 群 → TG
qqbot/group/<group_openid>=discord/ch123456      # qqbot 群 → DC
telegram/-100111=qqbot/group/<group_openid>      # TG → qqbot 群
telegram/-100111=qqbot/private/<user_openid>     # TG → qqbot 单聊
discord/ch123456=qqbot/channel/<channel_id>      # DC → qqbot 频道
```

### QQ Bot 昵称绑定与历史

官方 API 不返回显示名，转发只能先显示短 id，管理员绑定后才换成昵称：

```
@bot @某人 宝宝          # 按 @ 绑定
@bot 291A162 宝宝        # 按转发里看到的 7 位前缀绑定
@bot 历史                # 最近 5 条，id + 正文
```

绑定结果存在 `var/state/qqbot-nick/<group_openid>`（`<openid>\t<昵称>`，后写覆盖、可无限次改），适配器和转发都读它。
历史存在 `var/state/qqbot-hist/<group_openid>`（`<msg_id>\t<openid>\t<正文>`），按 `QQBOT_HIST_KEEP`（50）裁剪；
`历史` 只输出最新 `QQBOT_HIST_SHOW`（5）条。只有 `QQBOT_ADMINS` 里的 id 能绑定；管理命令在分发前被消费，不会进同步。

## Webhook 鉴权

设置 `WEBHOOK_SECRET` 后，所有 webhook URL 必须带 `?token=xxx`。鉴权失败返回真实 HTTP 错误码，
不再返回 200 + 正文 403（平台会把 200 当作投递成功而停止重试）：

| 情况 | 状态码 |
| --- | --- |
| token 缺失 / 错误 | `403` |
| body 超过体积上限 | `413` |
| 上游不可用 / 配置异常 | `503` |
| qqbot 回调 Ed25519 签名错误 | `401` |
| 受理成功 | `200`（qqbot 事件为 `{"op":12,"d":{}}`） |

**QQ Bot 有独立 token**：`/qqbot` 优先用 `QQBOT_WEBHOOK_TOKEN`，其次才是 `WEBHOOK_SECRET`。当 `WEBHOOK_SECRET`
含 `#` `<` `;` 时必须改用它——这些字符会让回调 URL 在平台侧被截断，而 `QQBOT_WEBHOOK_TOKEN` 限定
`[A-Za-z0-9_-]`。

**Ed25519**：每个 qqbot 回调都用 AppSecret 派生的密钥（`hush-ed25519` 子模块）校验
`X-Signature-Ed25519` + `X-Signature-Timestamp`。`op=13`（URL 校验）在事件路径之前应答，同样返回签名。
验签行为受 `QQBOT_VERIFY_SIG` 控制：`auto` / `1`（失败即拒）/ `0`（关闭）。密钥永不进日志——
`api.sh?action=config` 只给 `token_masked:"***"`，并把 `TG_API_BASE`（`https://host/bot<TOKEN>`）
经 `_api_scrub_url` 打码。

## HTTP 传输

Ayu.Core 使用原生 TCP + TLS 处理所有 HTTP/HTTPS 请求——`nc` 负责 TCP 连接，`ssl_client` 负责 TLS 加密。不依赖 `wget` 或 `curl`。

**为什么不用 wget**：BusyBox wget 的 `--post-file` 通过 C 标准库读取文件，遇到 `\x00`（null 字节）即当作字符串终止符截断；`--post-data` 同理，shell 参数本身就是 null 结尾字符串。图片和文件传输必须保留所有字节值，wget 无法胜任。

**工作方式**：

| 协议 | 传输方式 |
|------|----------|
| HTTP (QQ API) | `cat request \| nc host port` |
| HTTPS (Telegram/Discord) | `nc host 443 -e wrapper`，wrapper 内用 `ssl_client -s FD -n SNI` 做 TLS |

原始 HTTP 响应解析出状态码和 body，支持 chunked transfer encoding 重组。所有内部变量使用 `_h` 前缀避免 hush 全局变量冲突。

## 网络可达性

如果部署环境无法直连 `api.telegram.org` 或 `discord.com`，使用 Cloudflare Worker 或其他边缘计算服务做正向代理：

1. 部署 CF Worker，将请求代理到目标 API
2. 设置 `TG_API_HOST=你的worker域名`（Discord 对应设 `DC_API_BASE`）
3. 部署在边缘节点的 Worker 通常与主流 API 提供商有直连路由
4. 可用 `X-Ayu-Token` 等自定义头部做边缘 WAF 鉴权

### TLS 支持

Ayu.Core 使用 busybox 自带的 `ssl_client` 进行 TLS 协商。**无需外部 SSL 库或 CA 证书包。**

**TLS 版本：仅 1.2**（BusyBox 1.37.0 `ssl_client` 仅支持 TLS 1.2——无法降级到 TLS 1.0/1.1，也不支持 TLS 1.3）。

**支持的加密套件**（默认全部启用）：

| 套件名称 | 密钥交换 | 加密 | 完整性校验 |
|---------|---------|------|-----------|
| `ECDHE-RSA-AES128-GCM-SHA256` | ECDHE | AES-128-GCM | AEAD |
| `ECDHE-ECDSA-AES128-GCM-SHA256` | ECDHE (ECDSA) | AES-128-GCM | AEAD |
| `ECDHE-RSA-AES128-CBC-SHA256` | ECDHE | AES-128-CBC | SHA256 |
| `ECDHE-ECDSA-AES128-CBC-SHA256` | ECDHE (ECDSA) | AES-128-CBC | SHA256 |
| `RSA-AES128-GCM-SHA256` | RSA | AES-128-GCM | AEAD |
| `RSA-AES128-CBC-SHA256` | RSA | AES-128-CBC | SHA256 |
| `RSA-AES256-CBC-SHA256` | RSA | AES-256-CBC | SHA256 |

**支持的椭圆曲线：** P256 (secp256r1)、X25519。

**重要限制：**
- 不验证 TLS 证书（不校验服务器证书——信任基于网络层）
- 如果上游服务器要求 TLS 1.3（例如部分 Cloudflare zone 开启了最低 TLS 1.3），请求将在 TLS 握手阶段失败
- 若目标需要 TLS 1.3，可通过 CF Worker 或反向代理中转

## 错误处理

hush 无 `trap ERR`，错误在各层逐级 **prepend**（不覆盖）：

```
qq.send_group: qq.send_group_message: http failed after 2 retries: http://x:8080/api/... (connection refused)
```

```sh
json_get "$resp" key || die "missing key"
# → Ayu.Core ERROR (line 23): missing key
```

> **重要**: hush 没有局部变量。工具函数参数必须直接用 `$1` `$2` `$3`——赋给命名变量（如 `_msg="$3"`）会污染调用方的同名变量。

## 运行测试

```sh
# 全部测试 (mock_http, 无需 API key)
docker run --rm -v $(pwd):/ayu busybox:musl hush /ayu/test/run.sh

# 单个分类
docker run --rm -v $(pwd):/ayu busybox:musl hush -c "
  cd /ayu && . ./lib/core.sh && . ./test/helper.sh && . ./test/test_qq_message.sh
"
```

**400 tests, 0 failures。**

| 套件 | 文件 | 用例 |
| --- | --- | --- |
| QQ (Milky) | `test_qq_message`、`test_qq_system`、`test_qq_webhook` | 29 |
| QQ Bot（官方） | `test_qqbot`、`test_qqbot_admin`、`test_qqbot_commands` | 98 |
| QQ Bot 同步 | `test_sync_qqbot` | 32 |
| Telegram | `test_telegram` | 16 |
| Discord | `test_discord` | 32 |
| 跨平台同步 | `test_sync`、`test_sync_tmpvars` | 29 |
| HTTP 传输 | `test_http`、`test_headers` | 90 |
| 安全 / 脱敏 | `test_router_auth`、`test_webhook_auth`、`test_scrub` | 18 |
| 分发与 API | `test_dispatch`、`test_api` | 11 |
| URL / 日志 / 维护 | `test_url`、`test_log`、`test_maint` | 45 |

qqbot 的 130 条拆开是：`test_qqbot.sh` 45（webhook 入口、op=13、op=0 ACK、401/403、去重）、
`test_qqbot_admin.sh` 40（绑定/改名/未变化/历史/全量流）、`test_qqbot_commands.sh` 13（内置命令）、
`test_sync_qqbot.sh` 32（qqbot↔TG/DC 转发、附件、撤回）。

测试要求 submodule 已初始化（`git submodule update --init`），否则 `test/run.sh` 会在
`hush-json/lib/json.sh` 处直接失败。

## 关键约束

- **busybox:musl** — 无 bash, gawk, curl, jq, Python
- **nc + ssl_client** — 原生 TCP + TLS 传输（替代 wget，二进制安全）
- **httpd CGI** — 路径写死 `/cgi-bin/`，`H:` 指令不启用 CGI
- **hush** — 无数组、无 `trap ERR`、无局部变量
- **awk** — 变量名 ≤3 字符，`"\n"` 是字面量
- **JSON 转义** — 只解析 `\"` `\\`，`\uXXXX` 通过 `utf8_decode` 额外处理
- **$() 禁忌** — 设置 `_ERROR` 的函数不能放 subshell

## 面板（webui）

`webui/` 是零依赖面板（原生 HTML/CSS/JS），由同一个 httpd 提供，数据来自只读 JSON API：

| 接口 | 用途 |
|---|---|
| `/cgi-bin/api.sh?action=status` | 运行时长、平台状态、状态/日志/媒体体积、上次维护时间 |
| `/cgi-bin/api.sh?action=logs&which=bot\|cron\|error&lines=N` | 日志尾部（已脱敏） |
| `/cgi-bin/api.sh?action=sync` | 已配置的同步映射 |
| `/cgi-bin/api.sh?action=config` | 非敏感配置（密钥仅显示是否已配置） |

设了 `WEBHOOK_SECRET` 时需带 `&token=<WEBHOOK_SECRET>`；前端只存在 `sessionStorage`，不落盘、不回显。

## 维护清理

`plugin/maint/clean.sh` 在启动时（`cgi-bin/start.sh`）和每天由 `etc/crontab` 各跑一次：

- `var/log/{bot,error,cron}.log` 超过 5/5/2 MB 时轮转（保留 `.1`/`.2`）
- 清理 `/tmp` 里残留的临时文件（`ayu-*`、`tg-up-*`、`tg-api.*`、`dc-*-resp*` 等）
- 修剪 `var/state/msg-map{,-rev}` 路由表：删除 **30 天**前的条目，每个会话最多保留 **5000** 条（`maint_trim_state`）
- 不删除 `dc-cursor`、聊天内容、`/tmp/img` 转发缓存
- 修剪后 `var/state` 仍超过 3 GB 时写一条告警

可调参数（环境变量或 `etc/config.sh`）：

| 变量 | 默认 | 含义 |
|---|---|---|
| `MAINT_STATE_KEEP_DAYS` | `30` | 删除超过 N 天的映射条目 |
| `MAINT_STATE_KEEP_ITEMS` | `5000` | 单会话条目上限 |
| `MAINT_STATE_MIN_ITEMS` | `200` | 单会话最少保留条数 |
| `MAINT_STATE_DRY` | `0` | `1` = 只统计不删除 |
