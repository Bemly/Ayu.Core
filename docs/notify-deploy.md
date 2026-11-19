---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: d543d32bdd5b025565a7748d1464514e_0219ddbde45311f18b4e525400248c00
    ReservedCode1: MufftGRmfXr+7AmCQinoVQtV6YtS4WB0Ztea6Dalmo/teYU71NamnTz8WTTlaJwPYy6NDlOiQM9LsFTqgmXV9UznttaIlpUosWpmO335AxWDF2a8cO+mfvNLANqFfDxylmqNN9gc+s490GPaH9Fbdvo0yHj72RbOtHenSULyfdhGq4+/pIwIVDfo0GI=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: d543d32bdd5b025565a7748d1464514e_0219ddbde45311f18b4e525400248c00
    ReservedCode2: MufftGRmfXr+7AmCQinoVQtV6YtS4WB0Ztea6Dalmo/teYU71NamnTz8WTTlaJwPYy6NDlOiQM9LsFTqgmXV9UznttaIlpUosWpmO335AxWDF2a8cO+mfvNLANqFfDxylmqNN9gc+s490GPaH9Fbdvo0yHj72RbOtHenSULyfdhGq4+/pIwIVDfo0GI=
---

# notify 统一通知网关 v2（qqbot 通道）

一个 HTTP 入口，把同一条通知同时落到 qqbot 群/单聊、Telegram、Discord，并把用户在这些平台上的**任意互动事件**回传到调用方 URL。

- 入口：`POST /cgi-bin/router.sh/notify?token=<NOTIFY_WEBHOOK_TOKEN>`
- 请求体：`application/json`
- 响应：`{"ok":true,"sent":N,"failed":M}`；被拒时 `{"ok":false,"error":"..."}`

---

> **术语约定（本文严格区分，勿混用）**
>
> | 名词 | 指什么 | 代码位置 | 能力边界 |
> |---|---|---|---|
> | **qqbot** | QQ 官方机器人（群/单聊），走 QQ 开放平台 API | `adapter/qqbot/`（本次**未改动**） | 支持 markdown(msg_type=2)、keyboard 按钮、图文卡片(8)、富媒体(7)、撤回、@、LaTeX、预存图 |
> | **QQ 个人号** | 个人账号，走 milky / OneBot 协议 | `adapter/qq/`（本次**未改动**） | **纯文本only**：无 markdown、无按钮、无卡片，`to` 名写 `qq:` |
>
> 下文所有「qqbot xxx」均指官方机器人通道；涉及个人号的限制另起段落说明。

## 1. 请求字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `to` | string[] | 目标列表，`platform:scene:id` 或 `platform:id`。`qqbot:group:<group_openid>`、`qqbot:c2c:<user_openid>`、`telegram:chat:<chat_id>`、`discord:channel:<channel_id>` |
| `text` | string | 正文。`format=markdown` 时按 Markdown 渲染（支持标题/表格/代码块/LaTeX/`qqbot-media://` 图片） |
| `format` | string | `text`(默认) / `markdown`。qqbot 侧 markdown 对应 `msg_type=2` |
| `card` | object | qqbot 图文卡片（`msg_type=8`），原样透传为 `card` 字段。**与按钮互斥**，带 card 时按钮被丢弃 |
| `media` | object | 富媒体（`msg_type=7`）：`{"file":"/abs/a.png"}` 或 `{"url":"https://..."}` 或 `{"file_info":"..."}`，可选 `type`(1 图片/2 视频/3 语音/4 文件) |
| `images` | string[] | 仅 markdown 生效：本地路径（自动上传素材库）/ `token:<id>` / `qqbot-media://image/v1/<id>`，按 `![img #200px #150px](...)` 插入正文末尾 |
| `at` | string[] | 仅 markdown 生效：`group_member_openid` 列表，渲染为 `<qqbot-at-user id="..." />` 置于正文前 |
| `at_all` | bool | `@全体成员`，需机器人为群管理员，**每群每天仅 1 次** |
| `reply_to` | string | 引用回复的 `message_id`。实测引用机器人自身消息可用；引用他人消息受平台侧限制 |
| `msg_id` / `event_id` / `msg_seq` | string/int | 被动回复三件套（收到消息后回复时必须带，`msg_seq` 默认 1） |
| `recall` | string \| object[] | 撤回消息：字符串为“本请求所有目标撤回这条 id”；数组为 `[{"to":"...","message_id":"..."}]` 批量撤回，三平台各自走原生 DELETE |
| `buttons` | object[] | 按钮数组，见 §2 |
| `callback` | string | 互动事件回传 URL，见 §3 |

单条请求最多 `NOTIFY_MAX_TARGETS`(默认 10) 个目标，逐个发送、逐个计数。

---

## 2. 按钮

```json
{"id":"retry","label":"重试","data":"k=v","kind":"callback",
 "style":1,"row":0,"group":"g1","visited_label":"已点","enter":false,"reply":false,
 "url":"https://example.com"}
```

| 字段 | 说明 |
|---|---|
| `id` | 按钮标识，回传 `button_id`。缺省 `btn<序号>` |
| `label` | 文案，**qqbot 上限 10 字符**，超长只告警不拦截（让调用方看到平台真实报错） |
| `kind` | `callback`(默认) / `url` / `cmd`。`type` 字段同等生效，也接受 `0/1/2` |
| `data` | 回调/指令载荷。`callback` 类会自动追加 `&_k=<key>` 用于回传定位 |
| `url` | `kind=url` 时的跳转地址 |
| `style` | qqbot `render_data.style`：`0` 灰线框、`1` 蓝线框(默认)、`3` 白底红字、`4` 蓝底白字 |
| `row` | 行号，同 `row` 的按钮并排。缺省“一按钮一行”（qqbot 会挤压同一行内的长中文标签） |
| `group` | 单选组 ID，同组内一个被点后其余置灰。仅 qqbot `kind=cmd` 有效 |
| `visited_label` | 点击后文案，缺省同 `label` |
| `enter` / `reply` | 仅 qqbot `kind=cmd`：点击直接发送 / 带引用发送。`enter` 仅单聊 |

平台映射：

| 语义 | qqbot `action.type` | Telegram | Discord |
|---|---|---|---|
| callback | `1` | `callback_data="<id>\|<data>"` | `custom_id="<id>\|<data>"`, style 1 |
| url | `0` | `{"url": ...}` | style 5 + `url` |
| cmd | `2`（带 `enter`/`reply`/`group_id`） | 降级为 callback | 降级为 callback |

---

## 3. 事件回传

点击/操作后 `POST callback`，`Content-Type: application/json`：

```json
{"event":"button","platform":"qqbot","scene":"group","chat":"G1","user":"U1",
 "button_id":"retry","data":"k=v","message_id":"M1",
 "interaction_id":"I11","interaction_type":11,"fallback":false}
```

| `event` | 触发源 |
|---|---|
| `button` | qqbot type=11（消息按钮）、TG `callback_query`、DC `MESSAGE_COMPONENT` |
| `menu` | qqbot type=12（快捷菜单）、TG `data` 以 `menu:` 开头 |
| `feedback` | qqbot type=13（消息反馈） |
| `clear_session` | qqbot type=14（清除会话） |
| `story` | qqbot type=15（进入/退出故事） |
| `story_action` | qqbot type=16（故事操作） |
| `modal` | Discord `MODAL_SUBMIT` |
| `interaction` | qqbot 其他/未知 type |

**key 解析与 `fallback`**：按钮自带 `_k`，一切正常则 `fallback=false`。反馈、清除会话、菜单这类事件本身不带载荷，`_k` 只能回退到**该会话最近一次发送时存的 key**（`var/state/notify-cb-last/<platform>-<chat>`），此时 `fallback=true`，`button_id` 可能为空，调用方应以“该会话最近一条通知”语义处理。`NOTIFY_RELAY_FALLBACK_LAST=0` 可关闭回退（这类事件将 return 2 继续匹配后续规则）。

回传超时 4s（`NOTIFY_HTTP_TIMEOUT`），失败只记日志不影响主流程；`_k` 映射保留 7 天（`NOTIFY_CB_TTL_DAYS`）。

---

## 4. 平台硬限制（实测）

| 限制 | 后果 |
|---|---|
| qqbot 纯文本(`msg_type=0`)带按钮 | 服务端 200，**客户端丢弃按钮**。网关已强制：带按钮/at/reply 时自动升 `msg_type=2` |
| qqbot 图文卡片 + 按钮 | `40011021 keyboard无效`。网关自动丢弃按钮并告警 |
| qqbot 图文卡片 `url`/`pic_url` 用 http | 参数校验 400，必须 https |
| qqbot `mqqapi://` 等 scheme 跳转 | 群聊 `40034028` 拒绝，只能用 `https://` 或 `appid:` |
| qqbot `@用户` | 仅 markdown 生效，`id` 必须是 `group_member_openid` |
| qqbot `@全体` | 需管理员 + 每群每天 1 次 |
| qqbot 按钮 label | ≤10 字符，平台构造器前置校验 |
| qqbot 撤回 | 2 分钟内，`DELETE /v2/groups/{gid}/messages/{mid}` |
| qqbot LaTeX / 表格 | API 放行（`$..$`、`$$..$$`），渲染由客户端决定，不做保证 |
| 预存图片 | `prepare → PUT → complete` 得 `qqbot-media://image/v1/<token>`，有效期 90 天 |
| 群聊无原生合并转发 | `msg_type=9`/`forward` 字段均无效，只能发 `.txt` 文件 |

qqbot 事件若推送里没有 `data.resolved`，`data`/`button_id` 可能为空，此时依赖 `_k` 回退定位，调用方应优先用 `message_id` 或 `fallback` 语义兜底。

---

## 5. 配置

| 变量 | 默认 | 说明 |
|---|---|---|
| `NOTIFY_WEBHOOK_TOKEN` | 空 | 必填，`?token=` 鉴权；未设则入口拒绝 |
| `NOTIFY_ALLOW_HOSTS` | 空 | callback 允许的主机白名单（空格分隔）。为空时仅拦回环/私网 |
| `NOTIFY_HTTP_TIMEOUT` | 4 | 回传超时秒数 |
| `NOTIFY_MAX_TARGETS` | 10 | 单请求最多目标数 |
| `NOTIFY_CB_TTL_DAYS` | 7 | `_k` 映射保留天数 |
| `NOTIFY_QQ_LABEL_MAX` | 10 | 按钮文案告警阈值 |
| `NOTIFY_RELAY_FALLBACK_LAST` | 1 | 无载荷事件是否回退到最近 key |

状态目录：`var/state/notify-cb/`（key→URL）、`var/state/notify-cb-last/`（platform-chat→最近 key）。

---

## 6. 安装与回滚

### 6.1 新环境（从基线仓库装）

```sh
cd /ayu
tar cf /root/ayu-notify-$(date +%s).tar \
    cgi-bin/router.sh lib/dispatch.sh etc/rules adapter/discord/webhook.sh
patch -p1 --dry-run < notify-gateway.diff   # 先干跑
patch -p1 < notify-gateway.diff             # 应用（新建 adapter/notify/）
chmod 750 adapter/notify/*.sh
sh -n cgi-bin/router.sh && sh -n adapter/notify/webhook.sh
```

`tmp/` 由 git 跟踪为空目录（`.gitkeep`），若被清理网关会自建；不用手动 mkdir。

配 token 后生效（两种任选）：

```sh
# 方式一：环境变量（cgi 进程可见即可）
NOTIFY_WEBHOOK_TOKEN=<32位随机hex>
# 方式二：写进 etc/config.prod.sh（推荐，随配置版本化）
NOTIFY_WEBHOOK_TOKEN="<32位随机hex>"
```

生成：`hexdump -n 24 -e '24/1 "%02x"' /dev/urandom`。
**不要复用 `WEBHOOK_SECRET`**——notify 的 token 会贴进第三方 CI 表单，必须能单独吊销。

### 6.2 回滚

```sh
cd /ayu
tar xf /root/ayu-notify-<时间戳>.tar    # 还原 4 个既有文件
rm -rf adapter/notify                    # 删新增目录
```

`var/state/notify-cb*` 可直接留着（不再被读取，7 天后由 TTL 自清）。

`lib/dispatch.sh` 的改动只有一处语义：handler 返回 **2** 视为“未消费，继续匹配下一条规则”，旧规则行为不变。

### 6.3 生产部署记录

| 项 | 值 |
|---|---|
| 部署时间 | 2026-11-20 04:01 |
| 容器 | `Ayu`（生产 `/ayu`） |
| 备份 | `/ayu/var/backup/notify-20261120-040148/pre.tar`；后续单文件备份 `/ayu/var/backup/notify-20261120-0449/` |
| token | 独立生成，仅存 `etc/config.prod.sh`，未入库 |
| 生产 E2E | 16 passed / 0 failed（鉴权、头顺序、SSRF、路由、3MB 超限、既有平台回归） |
| 后续修复 | `tmp/` 缺失自建（2026-11-20 04:49 单文件热更，md5 校验一致） |

---

## 7. 测试

| 脚本 | 覆盖 | 干净 checkout 结果 |
|---|---|---|
| `test/test_notify.sh` | 鉴权 403/200 头、SSRF 拦截、多目标分发、dispatch 返回码 2、relay 按钮、TG/DC 路由 | **42 PASS / 0 FAIL** |
| `test/test_notify_v2.sh` | markdown、card(8)、media(7)、images、at/at_all、reply_to、recall（单/批量）、按钮 style/row/url/cmd、qqbot type 12-16 全事件与 fallback、DC modal、TG url 按钮、入参校验、纯 JSON body | **60 PASS / 0 FAIL** |
| `test/run.sh`（全仓） | 既有基线 + notify 守卫跳过 | **509 passed / 0 failed** |

复跑：

```sh
sh test/test_notify.sh
sh test/test_notify_v2.sh
sh test/run.sh
```

两个 notify 脚本是独立套件，被 `test/run.sh` source 时自动 return（`_AYU_TEST_SOURCED=1`），不会污染总计数。

## 8. 与 QQ 个人号（milky / OneBot）的边界

本网关的 `to` 只认 `qqbot:` / `telegram:` / `discord:` 三种平台前缀，**不含 `qq:`**。

| 能力 | qqbot（官方机器人） | QQ 个人号（milky/OneBot, `adapter/qq/`） |
|---|---|---|
| 纯文本 | 支持 | 支持 |
| markdown | 支持（msg_type=2，客户端渲染） | **不支持**，只能发纯文本 |
| 按钮 keyboard | 支持（必须随 markdown 下发） | **不支持** |
| 图文卡片 | 支持（msg_type=8，不可带按钮） | **不支持** |
| 富媒体/图片 | 支持（msg_type=7、预存图 / 素材库） | 仅能发原生图片/CDN 图片，无卡片封装 |
| 互动事件回传 | type 11-16 全量 | 无平台级事件，只能靠文本命令 |
| 撤回 | 2 分钟内 DELETE | 依协议实现而定 |

因此：把 `format:"markdown"` 或 `buttons` 发给个人号，平台侧只能退化成纯文本或被丢弃，网关不做伪装降级。个人号通道本次未改动（`adapter/qq/` 与生产树逐字节一致）。
*（内容由AI生成，仅供参考）*
