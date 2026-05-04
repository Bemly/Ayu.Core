# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Target Runtime

All code runs inside **busybox:musl** (1.37.0) Docker container via OrbStack. No bash, no gawk, no curl, no jq, no Python. Available: hush shell, busybox awk, sed, grep, nc, ssl_client, httpd.

**Critical: Always test inside the busybox container, never on macOS.** macOS BSD tools differ significantly from BusyBox implementations.

```sh
docker cp script.sh busybox-musl:/tmp/ && docker exec busybox-musl sh /tmp/script.sh
docker run --rm -v $(pwd):/test busybox:musl sh /test/test/run.sh
```

## Repo Structure

```
Ayu.Core/                  # SNS bot framework (this repo)
├── hush-json/             # → git submodule: pure hush JSON interpreter
```

## Submodule

`hush-json/` is a git submodule → https://github.com/Bemly/hush-json. After changes to hush-json, update the pin in Ayu.Core:

```sh
cd hush-json && git pull origin main && cd .. && git add hush-json && git commit -m "update hush-json"
```

## Git workflow

**IMPORTANT: After ANY changes to either repo, commit AND push to GitHub immediately.**

- hush-json: https://github.com/Bemly/hush-json
- Ayu.Core: https://github.com/Bemly/Ayu.Core

```sh
# In hush-json: commit and push
cd /Users/bemly/cchaha/hush-json
git add -A && git commit -m "<message>" && git push

# In Ayu.Core: commit, push, and update submodule if hush-json changed
cd /Users/bemly/cchaha/Ayu.Core
git add -A && git commit -m "<message>" && git push
```

## BusyBox httpd CGI

**CGI path is hardcoded to `/cgi-bin/`.** `H:` directive only does URL rewriting (static files), NOT CGI. The repo uses `cgi-bin/` directory directly — no wrapper, no `H:` config needed. httpd auto-detects and executes scripts under `<home>/cgi-bin/`.

See memory: busybox-httpd-cgi.md

## BusyBox awk limitations

- Function signatures must be short: total line from `function` to `{` under ~55 chars
- Use 1-3 char variable names
- See memory: busybox-awk-limits.md

## NAS Production Testing

**All network and connectivity tests on the NAS MUST run inside the `Ayu` Docker container, NEVER on the NAS host.**

```sh
# RIGHT: inside the container
ssh fnOS 'docker exec Ayu sh -c "wget -q -O- https://tghook.bemly.moe/..."'

# WRONG: on the NAS host directly
ssh fnOS 'curl ...'  # GNU curl != busybox wget
```

## Production Verification Checklist

**After EVERY deployment to NAS, run ALL of these from inside the `Ayu` container:**

```sh
# 1. Auth: reject missing/wrong token (MUST return 403)
sudo docker exec Ayu wget -q -O- 'http://127.0.0.1:6160/cgi-bin/router.sh/qq' --post-data='{}'
sudo docker exec Ayu wget -q -O- 'http://127.0.0.1:6160/cgi-bin/router.sh/qq?token=bad' --post-data='{}'

# 2. Auth: accept correct token
sudo docker exec Ayu wget -q -O- \
  'http://127.0.0.1:6160/cgi-bin/router.sh/qq?token=REDACTED' \
  --post-data='{"event_type":"message_receive","data":{"sender_id":1,"message_scene":"group","group_id":1,"segments":[{"type":"text","data":{"text":"test"}}]}}' \
  --header='Content-Type: application/json'
# Expected: {"status":"ok"}

# 3. QQ API connectivity
sudo docker exec Ayu wget -q -O- -T 5 http://host.docker.internal:616/api/get_group_list \
  --header='Authorization: Bearer REDACTED' \
  --header='Content-Type: application/json' --post-data='{}'
# Expected: {"status":"ok","retcode":0,...}

# 4. TG API connectivity (via CF Worker, requires X-Ayu-Token)
sudo docker exec Ayu wget -q -O- -T 5 \
  --header='X-Ayu-Token: REDACTED' \
  https://tghook.bemly.moe/botREDACTED/getMe
# Expected: {"ok":true,"result":{...}}

# 5. Sync config exists
sudo docker exec Ayu cat /test/etc/sync.conf
```

**All checks must pass before considering deployment complete.**

**Why:** The NAS host has GNU wget and curl with different TLS/proxy/cert behavior than the busybox:musl container. Tests that pass on the host don't guarantee the container can do the same thing. This has caused multiple debugging dead ends. See memory: feedback_test_busybox.md

## Deploy workflow

**Modify locally → test in local Docker → then deploy to NAS. Never edit directly on NAS.**

```sh
# 1. Edit files locally
# 2. Test in local Docker
docker run --rm -v $(pwd):/test busybox:musl hush /test/test/run.sh
# 3. Only after 0 failures, deploy to NAS
sshpass -p '...' scp file.sh fnOS:/tmp/ && \
  ssh fnOS 'sudo cp /tmp/file.sh /vol1/1000/Ayu/path/file.sh && sudo chmod +x /vol1/1000/Ayu/path/file.sh'
# 4. Fix ALL permissions (CGI scripts silently fail without +x)
ssh fnOS 'sudo find /vol1/1000/Ayu -name "*.sh" -exec chmod +x {} \; && sudo chmod 777 /vol1/1000/Ayu/var/log'
# 5. Restart httpd on NAS
ssh fnOS 'sudo docker exec Ayu sh -c "killall httpd; cd /test && hush cgi-bin/start.sh"'
```

**Exception:** `etc/config.sh` and `etc/sync.conf` NAS values (tokens, hostnames) differ from local defaults. These can be edited on NAS directly or via env vars.

**Why:** Editing on NAS risks syntax errors in production. Local Docker catches them first.

## Coding patterns

- **Refactor repeated patterns into helpers**: when the same `_qq_call + json_get + error wrap` pattern appears across 20+ functions, extract ONE `_qq_api()` helper. Don't edit each copy individually.
- **Avoid `$()` for function calls that set `_ERROR`**: `$()` is a subshell, globals are lost. Use temp files.
- **`_ERROR` chain**: always prepend, never overwrite. Format: `module.func: $_ERROR`

## HTTP Transport (nc + ssl_client)

**Ayu.Core does NOT use wget.** All HTTP/HTTPS goes through `lib/http.sh` which uses raw TCP + TLS:

- **HTTP**: `cat request | nc host port`
- **HTTPS**: `nc host 443 -e wrapper.sh` where wrapper pipes through `ssl_client -s FD -n SNI`

**Why not wget**: BusyBox wget `--post-file` reads via C stdlib which treats `\x00` as string terminator, silently truncating binary data. `--post-data` has the same issue (shell args are null-terminated). Images and files must preserve all byte values. See memory: wget-binary-null-byte.md, nc-ssl-client.md.

All internal variables in `http.sh` use `_h` prefix (`_hraw`, `_hbody`, etc.) to avoid hush global variable collisions. **Never add variables named `_raw`, `_body`, or `_res` to http.sh** — they will corrupt callers that use those names.

## Proxy

macOS proxy at 127.0.0.1:7890. Pull images with:
```sh
HTTP_PROXY=http://127.0.0.1:7890 HTTPS_PROXY=http://127.0.0.1:7890 docker pull <image>
```
