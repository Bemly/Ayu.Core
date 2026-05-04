# Ayu.Core

> [English](README.md)

纯 shell SNS Bot 框架。运行在 busybox:musl 容器中，hush + httpd CGI + 原生 TLS 传输 + [hush-json](https://github.com/Bemly/hush-json)。

[![test](https://github.com/Bemly/Ayu.Core/actions/workflows/test.yml/badge.svg)](https://github.com/Bemly/Ayu.Core/actions/workflows/test.yml)

## 适配器覆盖

| 平台 | 端点 | 方法 | README |
|------|------|------|--------|
| QQ (LagrangeV2.Milky) | 29/29 | 27 | [adapter/qq/README.md](adapter/qq/README.md) |
| Telegram Bot API | 169/169 | 169 | [adapter/telegram/README.md](adapter/telegram/README.md) |
| Discord REST API v10 | 185 bot API | 135 | [adapter/discord/README.md](adapter/discord/README.md) |

## 架构

```
请求流:
  SNS平台 → webhook → httpd CGI → router.sh → adapter → dispatch.sh → handler → adapter → nc+ssl_client → SNS平台

Ayu.Core/
├── cgi-bin/                # CGI 脚本 (busybox httpd 写死 /cgi-bin/)
│   ├── start.sh            # 启动 httpd
│   └── router.sh           # CGI 入口 (平台路由 + token 鉴权)
├── lib/
│   ├── core.sh             # _ERROR 链, die(), hush-json + hush-url 引导
│   ├── http.sh             # HTTP/HTTPS via nc + ssl_client (GET/POST, 重试, chunked 解码)
│   ├── dispatch.sh         # 消息路由 + 插件接口 (etc/rules)
│   ├── log.sh              # 分级日志 (debug/info/warn/err)
│   └── url.sh              # url_encode/decode + utf8_decode (\uXXXX→UTF-8)
├── adapter/                # 平台适配器
│   ├── qq/                 # QQ — 6 文件, 15 种 segment, 8 种事件
│   ├── telegram/           # Telegram — 17 文件, 20 种 Update, 18 种内容类型
│   └── discord/            # Discord — 17 文件 (仅 REST 出站)
├── plugin/                 # 业务插件
│   └── sync/               # 跨平台消息同步: 文字/图片/文件/语音/视频/贴纸/表情反应/撤回
├── etc/                    # config.sh, rules, sync.conf, config.nas.sh (gitignore)
└── test/                   # 141 tests, 0 failures (mock_http, 无需 API key)
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
```

## 配置

```sh
# etc/config.sh — 所有值都可通过环境变量覆盖
QQ_HOST="host.docker.internal"   # bridge 用 host.docker.internal, host 用 127.0.0.1
QQ_PORT="616"
QQ_TOKEN=""                      # 通过环境变量或 config.nas.sh 设置

TG_TOKEN=""                      # @BotFather 获取的 Bot token
TG_API_HOST="api.telegram.org"   # 网络受限时用 CF Worker 中转
TG_API_SECRET=""                 # 边缘认证用的 X-Ayu-Token 头部

DC_TOKEN=""

BOT_PORT="6160"
WEBHOOK_SECRET=""                # 设了就要 ?token=xxx，否则 403
_LOG_LEVEL="1"                   # 0=trace, 1=info, 2=warn, 3=err
```

> 绝不要提交密钥。生产环境用 `etc/config.nas.sh`（已 gitignore）。  
> 完整示例见 `etc/config.nas.sh`。

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
```

## 消息分发

`etc/rules` — 每行一个规则：`<pattern>|<handler_file>|<handler_func>`

```
/ping|qq/handler.sh|handler_ping
/echo|qq/handler.sh|handler_echo
*|../plugin/sync.sh|sync_handler
```

规则从上到下匹配。命令 handler 先命中，末尾的 `*` 交给同步插件转发。

## 跨平台消息同步

详见 [plugin/sync/README.zh.md](plugin/sync/README.zh.md)

## Webhook 鉴权

设置 `WEBHOOK_SECRET` 后，所有 webhook URL 必须带 `?token=xxx`，否则返回 403。

特殊字符（`#` `<` `;` 等）通过 URL 编码处理——`url_encode`/`url_decode` 自动编解码。

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
docker run --rm -v $(pwd):/test busybox:musl hush /test/test/run.sh

# 单个分类
docker run --rm -v $(pwd):/test busybox:musl hush -c "
  cd /test && . ./lib/core.sh && . ./test/helper.sh && . ./test/test_qq_message.sh
"
```

**141 tests, 0 failures** — QQ(14) + Telegram(6) + Discord(26) + HTTP(4) + Dispatch(2) + Sync(17) + URL(26) + Log(4) + Auth(5) + Webhook(16)

## 关键约束

- **busybox:musl** — 无 bash, gawk, curl, jq, Python
- **nc + ssl_client** — 原生 TCP + TLS 传输（替代 wget，二进制安全）
- **httpd CGI** — 路径写死 `/cgi-bin/`，`H:` 指令不启用 CGI
- **hush** — 无数组、无 `trap ERR`、无局部变量
- **awk** — 变量名 ≤3 字符，`"\n"` 是字面量
- **JSON 转义** — 只解析 `\"` `\\`，`\uXXXX` 通过 `utf8_decode` 额外处理
- **$() 禁忌** — 设置 `_ERROR` 的函数不能放 subshell
