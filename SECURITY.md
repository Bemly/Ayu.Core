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
- The router returns HTTP 403 for missing or incorrect tokens.
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
- Volume mounts are read-only for code (`/vol1/1000/Ayu:/test`) and read-write only for shared image storage (`/vol1/1000/Lagrange/img:/tmp/img`).
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
- 代码卷挂载为只读（`/vol1/1000/Ayu:/test`），仅图片存储卷可读写（`/vol1/1000/Lagrange/img:/tmp/img`）。
- 容器仅能访问显式挂载的卷，无法访问宿主文件系统。
