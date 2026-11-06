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

- **Never commit secrets.** All tokens, passwords, and API keys must go through environment variables or `etc/config.nas.sh` (gitignored).
- The git history has been cleaned of leaked credentials. Before committing, always check `git diff` for sensitive patterns.
- Production secrets on the NAS are deployed via separate scp, never committed.

### Webhook Authentication

- Set `WEBHOOK_SECRET` in `etc/config.sh` to require `?token=<secret>` on all incoming webhook URLs.
- The router returns HTTP 403 for missing or incorrect tokens (the body is a JSON error, and the request is logged with the token masked).
- Bot/API/webhook credentials are masked at the logging layer (`_log_scrub` in `lib/log.sh`): `token=`, `secret=`, `Bot <token>`, `Bearer <token>` and `api.telegram.org/file/bot<token>` are replaced with `***` before anything reaches `var/log`. Existing credentials therefore never need to be rotated because of log exposure.
- The dashboard API (`cgi-bin/api.sh`) is read-only and reuses `WEBHOOK_SECRET`; it exposes credential *flags* (`true`/`false`) and a masked token, never the secrets themselves.
- Special characters in tokens (`#`, `<`, `;`, etc.) are handled via URL encoding.

### Network Security

- Outbound HTTPS goes through busybox `ssl_client` (TLS 1.2 only).
- TLS certificate validation is NOT performed — trust is based on network-layer isolation.
- Production deployments use Cloudflare Worker as a reverse proxy, with `X-Ayu-Token` header authentication at the edge.
- All containers run in a Docker bridge network. Internal services communicate via `host.docker.internal`, not `127.0.0.1`.

### Dependency Security

- The only external dependency is [hush-json](https://github.com/Bemly/hush-json), a git submodule under the same maintainer.
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

- **绝不提交密钥。** 所有 token、密码、API key 必须通过环境变量或 `etc/config.nas.sh`（gitignored）传入。
- git 历史已清理泄露凭据。提交前务必 `git diff` 检查敏感信息。
- 生产环境密钥通过独立的 scp 部署到 NAS，绝不提交。

### Webhook 认证

- 在 `etc/config.sh` 中设置 `WEBHOOK_SECRET`，所有 webhook URL 必须携带 `?token=<secret>`。
- 日志层统一脱敏（`lib/log.sh` 的 `_log_scrub`）：`token=`、`secret=`、`Bot <token>`、`Bearer <token>`、`api.telegram.org/file/bot<token>` 在写入 `var/log` 前一律替换为 `***`，因此历史日志泄露不构成轮换密钥的必要理由。
- 面板 API（`cgi-bin/api.sh`）只读，复用 `WEBHOOK_SECRET` 鉴权，只暴露密钥「是否已配置」的布尔值与掩码值，不返回明文。
- 缺失或错误的 token 返回 HTTP 403。
- token 中的特殊字符（`#`、`<`、`;` 等）通过 URL 编码处理。

### 网络安全

- 出站 HTTPS 通过 busybox `ssl_client`（TLS 1.2）。
- **不执行 TLS 证书验证** —— 信任基于网络层隔离。
- 生产部署使用 Cloudflare Worker 作为反向代理，边缘层通过 `X-Ayu-Token` 认证。
- 所有容器运行在 Docker bridge 网络中，内部服务通过 `host.docker.internal` 互访，而非 `127.0.0.1`。

### 依赖安全

- 唯一外部依赖为 [hush-json](https://github.com/Bemly/hush-json)，同一维护者的 git submodule。
- 无 npm、pip 等包管理器。
- 运行时镜像 `busybox:musl` 锁定特定版本。

### 运行时隔离

- Ayu.Core 作为容器内 pid 1 运行，无特权提升。
- `var/state/msg-map{,-rev}` 路由表只存*消息 ID 对照*（不含消息正文与媒体），每日修剪：超过
  `MAINT_STATE_KEEP_DAYS`（30 天）以及单会话超过 `MAINT_STATE_KEEP_ITEMS`（5000 条）的条目会被删除，
  `var/state/dc-cursor` 永不触碰。保留窗口可配置，`MAINT_STATE_DRY=1` 时只统计不删除。
- 代码卷为读写挂载（`/vol1/1000/Ayu:/ayu`）：需要写 `var/state` 消息映射、`var/log` 日志及热更新插件；图片存储卷同样读写（`/vol1/1000/Lagrange/img:/tmp/img`）。两个挂载都不是只读，请按有状态目录对待。
- 容器仅能访问显式挂载的卷，无法访问宿主文件系统。
