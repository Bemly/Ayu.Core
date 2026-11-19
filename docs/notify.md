# notify 网关 · 对接文档

版本：v2（2026-11-20 部署）
入口：`POST https://<你的域名>/cgi-bin/router.sh/notify?token=<NOTIFY_WEBHOOK_TOKEN>`

---

## 0. 先分清两个"QQ"

| 名词 | 指代 | 本网关是否覆盖 |
|---|---|---|
| **qqbot** | QQ 官方机器人（开放平台），群聊 / 单聊 | ✅ 完整覆盖：markdown、按钮、卡片、富媒体、撤回、@、LaTeX |
| **QQ 个人号** | 个人账号，milky / OneBot 协议 | ❌ 不在本网关，纯文本 only，无按钮/无 markdown/无卡片 |

`to` 里的 `qqbot:` 一律指官方机器人。个人号请走既有机器人命令通道，不要指望这里下发按钮。

---

## 1. 一分钟接入

```bash
curl -s -X POST "https://<域名>/cgi-bin/router.sh/notify?token=$TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "to": ["qqbot:group:<group_openid>"],
    "text": "构建完成 ✅",
    "buttons": [{"id":"log","label":"看日志","kind":"url","url":"https://ci.example.com/job/42"}]
  }'
```

返回：

```json
{"ok":true,"sent":1,"failed":0,
 "results":[{"target":"qqbot:group:<openid>","ok":true,"message_id":"ROBOT1.0_xxx"}]}
```

---

## 2. 鉴权

| 项 | 说明 |
|---|---|
| 形式 | URL 查询参数 `?token=<NOTIFY_WEBHOOK_TOKEN>` |
| 独立性 | 该 token **只**解锁 `/notify`，不能用于 `/web.sh`、`/discord`、`/telegram`、`/fnos` 等任何其它路径 |
| 缺失/错误 | `403`，纯文本 `403 Forbidden`，且不进入业务逻辑 |
| 轮换 | 改 `etc/config.prod.sh` 的 `NOTIFY_WEBHOOK_TOKEN` 后立即生效（每请求读配置，无需重启） |
| 建议 | 用独立 token，别复用 `WEBHOOK_SECRET`；放 Header 不支持，只能查询参数，故务必走 HTTPS |

> token 出现在 URL 里会进 access log。若日志对第三方可见，另加一层反代鉴权或定期轮换。

---

## 3. 请求体

`Content-Type: application/json`，**上限 2 MiB**（超了直接 `413`，不进业务逻辑）。

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `to` | string[] | 必填 | 目标列表，见 §3.1。上限 `NOTIFY_MAX_TARGETS`（默认 10） |
| `text` | string | — | 正文。`format=markdown` 时按 Markdown 渲染 |
| `format` | string | `text` | `text` / `markdown`。qqbot 侧 markdown = `msg_type=2` |
| `card` | object | — | qqbot 图文卡片（`msg_type=8`），原样透传。**与 buttons 互斥**，带 card 时按钮被丢弃并告警 |
| `media` | object | — | 富媒体（`msg_type=7`）：`{"file":"/abs/a.mp4","type":2}` / `{"url":"https://…","type":1}` / `{"file_info":"…"}`。`type`：1 图片 2 视频 3 语音 4 文件 |
| `images` | string[] | — | 仅 markdown 生效。本地绝对路径（自动上传素材库）/ `token:<id>` / `qqbot-media://image/v1/<id>`，以 `![img #200px #150px](…)` 追加到正文末尾 |
| `at` | string[] | — | 仅 markdown 生效。`group_member_openid` 列表，渲染为 `<qqbot-at-user id="…" />` 置于正文前 |
| `at_all` | bool | false | 仅 markdown；需机器人是管理员，且每群每天 1 次 |
| `reply_to` | string | — | 引用回复的 `message_id`。仅 markdown 生效 |
| `msg_id` | string | — | 被动回复场景的被动消息 ID（收到事件后 5 分钟内有效） |
| `event_id` | string | — | 被动回复场景的事件 ID |
| `msg_seq` | int | — | 同一 `msg_id` 下多条回复的去重序号，不填平台按 msg_id 去重可能只显示第一条 |
| `buttons` | object[] | — | 见 §4 |
| `recall` | string \| object[] | — | 撤回。字符串 = 对所有 `to` 撤回该 id；数组 = 逐条 `{"to","message_id"}` |
| `callback` | string | — | 按钮被点击 / 互动事件发生时的回传 URL，见 §6 |

### 3.1 目标格式

```
qqbot:group:<group_openid>
qqbot:c2c:<user_openid>
telegram:chat:<chat_id>
discord:channel:<channel_id>
```

两段式 `qqbot:<openid>` 等价于 `qqbot:c2c:<openid>`（缺 scene 时按 c2c 处理）。
未知前缀 → `404`；格式错 → 该目标判失败，其余目标照发。

---

## 4. 按钮

```json
{"id":"ack","label":"确认","kind":"callback","data":"order=42","style":1,"row":0}
```

| 字段 | 说明 |
|---|---|
| `id` | 必填，按钮标识，回传时原样带回（`button_id`） |
| `label` | 文案。**qqbot 上限 10 字符**，超长只告警不拦截 |
| `kind` | `callback`(默认) / `url` / `cmd` |
| `data` | `kind=callback` 时随回传带回，长度有限，别塞大对象 |
| `url` | `kind=url` 必填，必须 `https://`。qqbot 也接受 `appid:` 形式，`mqqapi://` 群聊会被拒 `40034028` |
| `style` | qqbot `render_data.style`：`0` 灰线框 / `1` 蓝线框（默认）/ `3` 白底红字 / `4` 蓝底白字。DC 映射 ButtonStyle（url 用 style 5） |
| `row` | 行号，同 `row` 并排；缺省一按钮一行（qqbot 同行的长中文会被挤压） |
| `group` | 单选组 ID，同组点一个其余置灰。仅 qqbot `kind=cmd` 有效 |
| `visited_label` | qqbot 点击后的按钮文案 |
| `enter` / `reply` | 仅 qqbot `kind=cmd`：点击直接发送 / 带引用发送。`enter` 仅单聊可用 |

**平台映射**

| kind | qqbot `action.type` | Telegram | Discord |
|---|---|---|---|
| `callback` | 1 | `callback_data` | `custom_id`（type 3 组件） |
| `url` | 0 | `url` | style 5 + url |
| `cmd` | 2（带 `enter`/`reply`/`group_id`） | 不支持 | 不支持 |

---

## 5. 用法示例

### 5.1 纯文本

```json
{"to":["qqbot:group:G","telegram:chat:100"],"text":"部署完成"}
```

### 5.2 Markdown + 按钮 + @

```json
{
  "to": ["qqbot:group:G"],
  "format": "markdown",
  "text": "**构建 #42 失败**\n- 分支 `main`\n- 耗时 3m12s",
  "at": ["<group_member_openid>"],
  "buttons": [
    {"id":"rerun","label":"重跑","kind":"callback","data":"job=42","row":0},
    {"id":"log","label":"日志","kind":"url","url":"https://ci.example.com/42","row":0}
  ],
  "callback": "https://ci.example.com/hook/notify"
}
```

### 5.3 图文卡片（不能带按钮）

```json
{"to":["qqbot:group:G"],"card":{"type":"template","title":"日报","preview":"...","fields":[]}}
```

### 5.4 图片 / 视频

```json
{"to":["qqbot:group:G"],"media":{"file":"/ayu/var/tmp/chart.png","type":1}}
```

### 5.5 引用回复 + 被动消息

```json
{"to":["qqbot:group:G"],"format":"markdown","text":"收到","reply_to":"<message_id>","msg_id":"<被动消息id>","msg_seq":2}
```

### 5.6 撤回

```json
{"recall":"<message_id>","to":["qqbot:group:G"]}
```

```json
{"recall":[{"to":"qqbot:group:G","message_id":"M1"},{"to":"telegram:chat:100","message_id":"7"}]}
```

> qqbot 撤回窗口 **2 分钟**，超时平台报错。

---

## 6. 响应

### 6.1 成功 / 部分失败

```json
{"ok":true,"sent":1,"failed":1,
 "results":[
   {"target":"qqbot:group:G","ok":true,"message_id":"ROBOT1.0_xxx"},
   {"target":"telegram:chat:100","ok":false,"error":"telegram.send HTTP 400"}
 ]}
```

- `ok`：整体是否有任一目标失败也返回 true，**以 `failed` 和 `results[].ok` 判断**
- `message_id`：仅发送类目标返回，撤回类不返回
- `error`：平台原始错误的裁剪文本

### 6.2 失败

```json
{"ok":false,"error":"..."}
```

| error | 触发 |
|---|---|
| `empty body` | 空 body |
| `missing text` | 无 text、无 recall、无 media、无 card |
| `callback url rejected` | callback 非法（scheme 非 http(s)、回环、私网、不在白名单） |
| `bad target scheme` | `to` 前缀不认识 |
| `too many targets` | 超过 `NOTIFY_MAX_TARGETS` |
| `bad json` | body 不是合法 JSON |

---

## 7. 事件回传

按钮点击、菜单、反馈、清除会话、故事事件全部 POST 到 `callback`。

### 7.1 Payload

```json
{
  "event": "button",
  "platform": "qqbot",
  "scene": "group",
  "chat": "<group_openid>",
  "user": "<user_openid>",
  "button_id": "ack",
  "data": "order=42",
  "message_id": "<message_id>",
  "interaction_id": "<interaction_id>",
  "interaction_type": "11",
  "fallback": false
}
```

| 字段 | 说明 |
|---|---|
| `event` | `button` / `menu` / `feedback` / `clear_session` / `story` / `story_action` / `modal` / `interaction`（未知 type 兜底） |
| `platform` | `qqbot` / `telegram` / `discord` |
| `scene` / `chat` / `user` | 群或单聊标识与触发者 |
| `button_id` / `data` | 按钮侧信息，`data` 已剥掉内部短键包装 |
| `message_id` | 被点击的那条消息 |
| `interaction_type` | 平台原始 type（qqbot 11-16、DC 3/5、TG 为 0） |
| `fallback` | `true` 表示该事件本身不带按钮载荷（qqbot type 12-16），`button_id`/`data` 取最近一次发送记录 |

### 7.2 qqbot 事件映射

| type | event | 说明 |
|---|---|---|
| 11 | `button` | 消息按钮 |
| 12 | `menu` | 快捷菜单 |
| 13 | `feedback` | 消息反馈 |
| 14 | `clear_session` | 清除会话 |
| 15 | `story` | 进入/退出故事 |
| 16 | `story_action` | 故事内操作 |

### 7.3 回传规则

- `Content-Type: application/json`，单次 POST，**不重试**，超时 `NOTIFY_HTTP_TIMEOUT`（默认 4s）
- 回调 2xx 视为成功，其余只记日志
- 回调目标排除：`localhost`、`127.*`、`0.*`、`10.*`、`192.168.*`、`169.254.*`、`::1`、`*.localhost`，以及解析到这些地址的域名（防 DNS rebinding）。确需访问内网时把主机名加进 `NOTIFY_ALLOW_HOSTS`（逗号分隔）
- 回传幂等由调用方负责：同一 `interaction_id` 可能因平台重投而重复到达

### 7.4 fallback 的开关与含义

qqbot 的 12-16 类事件不回传 `button_data`，网关回退到 `var/state/notify-cb-last/<platform>-<chat>` 里最近一次发送的按钮键。要关掉回退（这些事件直接不匹配 relay 规则）：

```
NOTIFY_RELAY_FALLBACK_LAST=0
```

---

## 8. 平台硬限制（实测，不是文档抄的）

| 现象 | 原因 / 处理 |
|---|---|
| 纯文本带按钮，客户端没按钮 | qqbot 只认 `msg_type=2` 的 keyboard。网关已强制：带 buttons/at/reply 时自动升 markdown |
| 图文卡片 + 按钮 → `40011021` | 卡片与 keyboard 互斥，网关自动丢按钮并告警 |
| 卡片 `url`/`pic_url` 用 http → 400 | 必须 https |
| `mqqapi://` scheme 按钮 → `40034028` | 群聊只允许 `https://` 与 `appid:` |
| `@用户` 不生效 | 仅 markdown；`id` 必须是 `group_member_openid`，不是 QQ 号 |
| `@全体` 报权限错 | 需管理员 + 每群每天 1 次 |
| 按钮 label 被拒 | ≤10 字符；网关只告警不截断，让调用方看到真实报错 |
| markdown 里图片不显示 | 本地图先 `images` 上传，或直接用 `qqbot-media://image/v1/<token>`（90 天有效） |
| 同一条被动消息回复不显示 | 补 `msg_seq` 递增 |
| 撤回失败 | 超 2 分钟 |

---

## 9. 安全设计

| 项 | 实现 |
|---|---|
| 鉴权隔离 | 独立 token，仅 `/notify` 生效 |
| SSRF | 回调 URL 白名单 + 私网/回环拦截 + 不允许非 http(s) |
| 请求体 | 2 MiB 硬上限，超出 413，不读 body |
| 头顺序 | CGI 头先输出、body 后输出，异常路径不重复输出头 |
| 平台响应 | 平台的原始 JSON 不回显到 HTTP body（只进日志），保证响应恒为单 JSON |
| 密钥 | 全部在 `etc/config.prod.sh`，gitignored；仓库只有空默认 |

---

## 10. 排障

| 现象 | 查 |
|---|---|
| `403 Forbidden` | token 是否与 `NOTIFY_WEBHOOK_TOKEN` 一致；是否误用了 `WEBHOOK_SECRET` |
| `404` | 路径是否 `/cgi-bin/router.sh/notify`；`to` 前缀是否拼错 |
| `413` | body 超 2 MiB，图片走 `images`/`media` 不要 base64 塞进 `text` |
| 响应前多出 `{"id":"ROBOT1.0…"}` | 旧版 bug，已修；确认线上 `adapter/notify/webhook.sh` md5 为 `65466c29…` |
| 按钮点了没反应 | 是否 `kind=url` 且 URL 是 http；是否群聊用了 `mqqapi://` |
| 回调没到 | 日志 `notify: relay ok/failed`；`fallback` 事件是否被 `NOTIFY_RELAY_FALLBACK_LAST=0` 关掉 |
| 一条消息里两个 JSON 拼接 | 同第 4 行，旧版泄漏，已修 |

日志：`/ayu/var/log/`，关键字 `notify:`。

---

## 11. 客户端示例

### Python

```python
import requests

def notify(text, buttons=None, target="qqbot:group:G", cb=None):
    body = {"to": [target], "text": text}
    if buttons: body["buttons"] = buttons
    if cb: body["callback"] = cb
    r = requests.post(f"{BASE}/cgi-bin/router.sh/notify",
                      params={"token": TOKEN}, json=body, timeout=10)
    r.raise_for_status()
    return r.json()
```

### Node

```js
const r = await fetch(`${BASE}/cgi-bin/router.sh/notify?token=${TOKEN}`, {
  method: 'POST',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({to:['qqbot:group:G'], text:'构建完成'})
});
const j = await r.json();
if (j.failed) console.error(j.results);
```

---

## 12. 配置项

| 变量 | 默认 | 说明 |
|---|---|---|
| `NOTIFY_WEBHOOK_TOKEN` | 空 | 必填，为空则 `/notify` 一律 403 |
| `NOTIFY_ALLOW_HOSTS` | 空 | 回调 SSRF 白名单，逗号分隔主机名 |
| `NOTIFY_HTTP_TIMEOUT` | 4 | 回传超时（秒） |
| `NOTIFY_MAX_TARGETS` | 10 | 单次请求目标上限 |
| `NOTIFY_CB_TTL_DAYS` | 7 | 按钮内部短键 → callback 映射保留天数 |
| `NOTIFY_RELAY_FALLBACK_LAST` | 1 | 12-16 类无载荷事件是否回退到最近按钮 |
| `NOTIFY_QQ_LABEL_MAX` | 10 | 按钮文案告警阈值 |

---

## 13. 变更记录

| 版本 | 日期 | 内容 |
|---|---|---|
| v2 | 2026-11-20 | 全事件覆盖（type 11-16）、button kind/style/row/group、card/media/images/at/reply/msg_seq/recall、DC modal；修复平台响应泄漏进 CGI body |
| v1 | 2026-11-19 | 首版：text + buttons + callback 闭环，三平台路由 |
