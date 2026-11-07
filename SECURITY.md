# Security Policy

## Reporting a Vulnerability

**Do not open a public issue.** Report security issues directly to the maintainer via GitHub Security Advisories or email.

## Supported Versions

| Version | Supported |
|---------|-----------|
| main branch (latest) | Yes |

## Security Model

Ayu.Core is a pure shell bot framework designed to run inside an isolated Docker container (busybox:musl). It has no external dependencies beyond the shell runtime and a single git submodule (hush-json).

### Secrets Management

- **Never commit secrets.** All tokens, passwords, and API keys must go through environment variables or the gitignored production overlay `etc/config.prod.sh` (sourced when `AYU_ENV=prod`; start from `etc/config.prod.example.sh`). The repo's `etc/config.sh` holds empty defaults only.
- The git history has been cleaned of leaked credentials. Before committing, always check `git diff` for sensitive patterns.
- Production secrets on the NAS are deployed via separate scp, never committed.

### Webhook Authentication

- Set `WEBHOOK_SECRET` in `etc/config.sh` to require `?token=<secret>` on all incoming webhook URLs.
- The router returns real HTTP status codes: `403` for a missing/wrong token, `413` for an oversized body, `503` for configuration/upstream failure, `401` for a bad QQ Bot Ed25519 signature, `200` on success. Returning 200 with a 403 body was an early bug — platforms treat 200 as delivered and stop retrying.
- `/qqbot` uses `QQBOT_WEBHOOK_TOKEN` when set (URL-safe alphabet `[A-Za-z0-9_-]`), falling back to `WEBHOOK_SECRET`. Use the dedicated token when `WEBHOOK_SECRET` contains `#`, `<` or `;`. Even when the secret is missing, `/qqbot` never falls back to an unauthenticated mode: Ed25519 signature verification still applies on every event.
- Bot/API/webhook credentials are masked at the logging layer (`_log_scrub` in `lib/log.sh`): `token=`, `secret=`, `Bot <token>`, `Bearer <token>` and `api.telegram.org/file/bot<token>` are replaced with `***` before anything reaches `var/log`. Existing credentials therefore never need to be rotated because of log exposure.
- The dashboard API (`cgi-bin/api.sh`) is read-only and reuses `WEBHOOK_SECRET`; it exposes credential *flags* (`true`/`false`) and a masked token, never the secrets themselves.
- Special characters in tokens (`#`, `<`, `;`, etc.) are handled via URL encoding.

### QQ Bot Authentication (Ed25519)

Every callback to `/cgi-bin/router.sh/qqbot` is verified before it is parsed:

| Header | Meaning |
|--------|---------|
| `X-Signature-Ed25519` | Ed25519 signature (hex) over `timestamp + body` |
| `X-Signature-Timestamp` | Unix seconds, part of the signed payload |

- The signing key is derived deterministically from `QQBOT_APP_SECRET` (seed) via the [hush-ed25519](https://github.com/Bemly/hush-ed25519) submodule — no key files, no rotation.
- `op=13` (URL validation) is answered *before* event handling and returns `plain_token` + `signature`.
- `QQBOT_VERIFY_SIG` selects the mode: `auto` (verify when a secret and the Ed25519 backend are both available), `1` (fail closed — unsigned callbacks are rejected), `0` (off, not recommended).
- Signature failures return `401` and are logged without the signature value or the secret.
- `api.sh?action=config` never returns the secret: `token_masked:"***"`, and `TG_API_BASE` (shaped `https://host/bot<TOKEN>`) is passed through `_api_scrub_url` before serialisation.

### Network Security

- Outbound HTTPS goes through busybox `ssl_client` (TLS 1.2 only).
- TLS certificate validation is NOT performed — trust is based on network-layer isolation.
- Production deployments use Cloudflare Worker as a reverse proxy, with `X-Ayu-Token` header authentication at the edge.
- All containers run in a Docker bridge network. Internal services communicate via `host.docker.internal`, not `127.0.0.1`.

### Dependency Security

- The only external dependencies are two git submodules under the same maintainer: [hush-json](https://github.com/Bemly/hush-json) (JSON) and [hush-ed25519](https://github.com/Bemly/hush-ed25519) (Ed25519 sign/verify in shell + busybox awk). Both are pinned by commit (`160000`); do not vendor them into the main tree.
- No npm, pip, or other package managers are involved.
- The runtime image (`busybox:musl`) is pinned to a specific version.

### Runtime Isolation

- Ayu.Core runs as pid 1 inside the container with no elevated privileges.
- The routing table under `var/state/msg-map{,-rev}` holds *message ids only* (never message bodies or
  media). It is trimmed daily — entries older than `MAINT_STATE_KEEP_DAYS` (30) and anything beyond
  `MAINT_STATE_KEEP_ITEMS` (5000) per conversation are removed; `var/state/dc-cursor` is never touched.
  Retention is configurable, and `MAINT_STATE_DRY=1` turns the trim into a report-only pass.
- Code volume is mounted read-write (`/vol1/1000/Ayu:/ayu`): the bot must persist `var/state` message maps, `var/log` logs and reloaded plugins. Shared image storage is mounted read-write as well (`/vol1/1000/Lagrange/img:/tmp/img`). Neither mount is read-only, so treat the host directory as state-bearing.
- The container has no access to the host filesystem beyond the explicitly mounted volumes.

---

# 安全策略

## 报告漏洞

**请勿公开发布 issue。** 直接通过 GitHub Security Advisories 或邮件向维护者报告安全问题。

## 支持的版本

| 版本 | 支持 |
|------|------|
| main 分支（最新） | 是 |

## 安全模型

Ayu.Core 是一个纯 shell bot 框架，运行在隔离的 Docker 容器（busybox:musl）中。除 shell 运行时和单个 git submodule（hush-json）外，无外部依赖。

### 密钥管理

- **绝不提交密钥。** 所有 token、密码、API key 必须通过环境变量或 gitignored 的生产覆盖文件 `etc/config.prod.sh` 传入（`AYU_ENV=prod` 时被 source，从 `etc/config.prod.example.sh` 起步）。仓库里的 `etc/config.sh` 只有空默认值。
- git 历史已清理泄露凭据。提交前务必 `git diff` 检查敏感信息。
- 生产环境密钥通过独立的 scp 部署到 NAS，绝不提交。

### Webhook 认证

- 在 `etc/config.sh` 中设置 `WEBHOOK_SECRET`，所有 webhook URL 必须携带 `?token=<secret>`。
- 日志层统一脱敏（`lib/log.sh` 的 `_log_scrub`）：`token=`、`secret=`、`Bot <token>`、`Bearer <token>`、`api.telegram.org/file/bot<token>` 在写入 `var/log` 前一律替换为 `***`，因此历史日志泄露不构成轮换密钥的必要理由。
- 面板 API（`cgi-bin/api.sh`）只读，复用 `WEBHOOK_SECRET` 鉴权，只暴露密钥「是否已配置」的布尔值与掩码值，不返回明文。
- 状态码如实返回：token 缺失/错误 `403`，body 超限 `413`，配置或上游异常 `503`，QQ Bot 签名错误 `401`，成功 `200`。早期版本用 200 + 正文 403，平台会当作投递成功而不再重试，已修正。
- `/qqbot` 优先用 `QQBOT_WEBHOOK_TOKEN`（限定 `[A-Za-z0-9_-]`），回退 `WEBHOOK_SECRET`；后者含 `#` `<` `;` 时会被平台截断，必须用专用 token。
- token 中的特殊字符（`#`、`<`、`;` 等）通过 URL 编码处理。

### QQ Bot 回调验签（Ed25519）

`/cgi-bin/router.sh/qqbot` 的每个回调都在解析前先验签：

| 头部 | 含义 |
| --- | --- |
| `X-Signature-Ed25519` | 对 `timestamp + body` 的 Ed25519 签名（hex） |
| `X-Signature-Timestamp` | Unix 秒，参与签名 |

- 签名密钥由 `QQBOT_APP_SECRET` 作为种子确定性派生（[hush-ed25519](https://github.com/Bemly/hush-ed25519) 子模块），无密钥文件、无需轮换。
- `op=13`（URL 校验）在事件处理之前应答，回 `plain_token` + `signature`。
- `QQBOT_VERIFY_SIG` 三态：`auto`（有 secret 且有 Ed25519 后端时自动开启）、`1`（失败即拒，未签名的回调一律拒收）、`0`（关闭，不推荐）。
- 验签失败返回 `401`，日志不记录签名值与 secret。
- `api.sh?action=config` 不返回 secret：`token_masked:"***"`；`TG_API_BASE`（形如 `https://host/bot<TOKEN>`）在序列化前过 `_api_scrub_url` 打码。

### 网络安全

- 出站 HTTPS 通过 busybox `ssl_client`（TLS 1.2）。
- **不执行 TLS 证书验证** —— 信任基于网络层隔离。
- 生产部署使用 Cloudflare Worker 作为反向代理，边缘层通过 `X-Ayu-Token` 认证。
- 所有容器运行在 Docker bridge 网络中，内部服务通过 `host.docker.internal` 互访，而非 `127.0.0.1`。

### 依赖安全

- 唯一外部依赖为两个同维护者的 git submodule：[hush-json](https://github.com/Bemly/hush-json)（JSON）与 [hush-ed25519](https://github.com/Bemly/hush-ed25519)（shell + busybox awk 的 Ed25519 签名/验签）。两者都以 commit 固定（`160000`），不要把内容平铺进主仓。
- 无 npm、pip 等包管理器。
- 运行时镜像 `busybox:musl` 锁定特定版本。

### 运行时隔离

- Ayu.Core 作为容器内 pid 1 运行，无特权提升。
- `var/state/msg-map{,-rev}` 路由表只存*消息 ID 对照*（不含消息正文与媒体），每日修剪：超过
  `MAINT_STATE_KEEP_DAYS`（30 天）以及单会话超过 `MAINT_STATE_KEEP_ITEMS`（5000 条）的条目会被删除，
  `var/state/dc-cursor` 永不触碰。保留窗口可配置，`MAINT_STATE_DRY=1` 时只统计不删除。
- 代码卷为读写挂载（`/vol1/1000/Ayu:/ayu`）：需要写 `var/state` 消息映射、`var/log` 日志及热更新插件；图片存储卷同样读写（`/vol1/1000/Lagrange/img:/tmp/img`）。两个挂载都不是只读，请按有状态目录对待。
- 容器仅能访问显式挂载的卷，无法访问宿主文件系统。
