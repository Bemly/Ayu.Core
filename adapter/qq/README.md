# QQ (Milky) API Reference

> Protocol spec from CharonAnchor/Lagrange.Milky; implemented by LLOneBot
> 29 endpoints, 100% covered in Ayu.Core adapter

**Not the official QQ Bot API.** This adapter talks to a locally hosted Lagrange/LLOneBot instance
over HTTP with numeric QQ numbers. If you are looking for the official OpenAPI v2 (webhook, `openid`,
Ed25519 signatures), see [`../qqbot/README.md`](../qqbot/README.md).

| | `qq` (this adapter) | `qqbot` (official) |
|---|---|---|
| ID space | numeric `group_id` / `user_id` | `group_openid` / `member_openid` / `user_openid` |
| Auth | `Authorization: Bearer <QQ_TOKEN>` | AppID + AppSecret token, Ed25519 webhook signatures |
| Transport | local HTTP, all POST | webhook in, HTTPS API out |
| Sender name | available in event | not returned; bind via `@bot @某人 昵称` |

**Protocol**: Milky (LagrangeV2-compatible, served by LLOneBot)
**Auth**: `Authorization: Bearer <QQ_TOKEN>`
**Base URL**: `http://<QQ_HOST>:<QQ_PORT><QQ_PREFIX>api`
**Method**: All endpoints use POST
**Response envelope**: `{"status":"ok"/"failed","retcode":<int>,"data":{...}}`

---

## Message API

### send_group_message

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| message | Segment[] | Yes |

Response: `{"message_seq": long, "time": long}`

### send_private_message

| Parameter | Type | Required |
|-----------|------|----------|
| user_id | long | Yes |
| message | Segment[] | Yes |

Response: `{"message_seq": long, "time": long}`

### get_message

| Parameter | Type | Required |
|-----------|------|----------|
| message_scene | string | Yes |
| peer_id | long | Yes |
| message_seq | long | Yes |

Response: `{"message": MessageBase}`

### get_history_messages

| Parameter | Type | Required |
|-----------|------|----------|
| message_scene | string | Yes |
| peer_id | long | Yes |
| start_message_seq | long | No |
| limit | int | No |

Response: `{"messages": MessageBase[], "next_message_seq": long?}`

### recall_group_message

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| message_seq | long | Yes |

### recall_private_message

| Parameter | Type | Required |
|-----------|------|----------|
| user_id | long | Yes |
| message_seq | long | Yes |

### get_resource_temp_url

| Parameter | Type | Required |
|-----------|------|----------|
| resource_id | string | Yes |

Response: `{"url": string}`

---

## Group API

### get_group_list

| Parameter | Type | Required |
|-----------|------|----------|
| no_cache | bool | No |

Response: `{"groups": Group[]}`

### get_group_info

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| no_cache | bool | No |

Response: `{"group": Group}`

### get_group_member_list

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| no_cache | bool | No |

Response: `{"members": GroupMember[]}`

### get_group_member_info

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| user_id | long | Yes |
| no_cache | bool | No |

Response: `{"member": GroupMember}`

### set_group_name

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| new_group_name | string | Yes |

### set_group_member_card

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| user_id | long | Yes |
| card | string | Yes |

### set_group_member_special_title

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| user_id | long | Yes |
| special_title | string | Yes |

### send_group_nudge

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| user_id | long | Yes |

### send_group_message_reaction

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| message_seq | long | Yes |
| reaction | string | Yes |
| is_add | bool | No |

### get_group_notifications

| Parameter | Type | Required |
|-----------|------|----------|
| start_notification_seq | long | No |
| is_filtered | bool | No |
| limit | int | No |

Response: `{"notifications": GroupNotificationBase[], "next_notification_seq": long?}`

### quit_group

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |

---

## Friend API

### get_friend_list

| Parameter | Type | Required |
|-----------|------|----------|
| no_cache | bool | No |

Response: `{"friends": Friend[]}`

### get_friend_info

| Parameter | Type | Required |
|-----------|------|----------|
| user_id | long | Yes |
| no_cache | bool | No |

Response: `{"friend": Friend}`

### send_friend_nudge

| Parameter | Type | Required |
|-----------|------|----------|
| user_id | long | Yes |
| is_self | bool | No |

---

## File API

### upload_group_file

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| file_uri | string | Yes |
| file_name | string | Yes |
| parent_folder_id | string | No |

Response: `{"file_id": string}`

### upload_private_file

| Parameter | Type | Required |
|-----------|------|----------|
| user_id | long | Yes |
| file_uri | string | Yes |
| file_name | string | Yes |

Response: `{"file_id": string}`

### get_group_file_download_url

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| file_id | string | Yes |

Response: `{"download_url": string}`

### delete_group_file

| Parameter | Type | Required |
|-----------|------|----------|
| group_id | long | Yes |
| file_id | string | Yes |

---

## System API

### get_login_info

No parameters.

Response: `{"uin": long, "nickname": string}`

### get_impl_info

No parameters.

Response: `{"impl_name": string, "impl_version": string, "qq_protocol_version": string, "qq_protocol_type": string, "milky_version": string}`

### get_cookies

| Parameter | Type | Required |
|-----------|------|----------|
| domain | string | Yes |

Response: `{"cookies": string}`

### get_user_profile

| Parameter | Type | Required |
|-----------|------|----------|
| user_id | long | Yes |

Response: `{"nickname": string, "qid": string, "age": int, "sex": string, "remark": string, "bio": string, "level": int, "country": string, "city": string, "school": string?}`

---

## Webhook Events

All events follow the envelope: `{"time": long, "self_id": long, "event_type": string, "data": {...}}`

| event_type | Description | Key data fields |
|-----------|-------------|----------------|
| `message_receive` | New message | `peer_id`, `sender_id`, `message_seq`, `segments[]`, `message_scene` |
| `message_recall` | Message recalled | `message_scene`, `peer_id`, `message_seq`, `sender_id`, `operator_id` |
| `friend_request` | Friend request | `initiator_id`, `comment`, `via` |
| `group_invitation` | Group invite | `invitation_seq`, `initiator_id`, `group_id` |
| `group_member_increase` | Member joined | `group_id`, `user_id`, `operator_id?` |
| `group_member_decrease` | Member left/kicked | `group_id`, `user_id`, `operator_id?` |
| `group_nudge` | Group nudge | `group_id`, `sender_id`, `receiver_id`, `display_action` |
| `bot_offline` | Bot disconnected | `reason` |

---

## Message Segments

### Incoming (from QQ server)

| type | Data fields |
|------|------------|
| `text` | `text` |
| `mention` | `user_id` |
| `mention_all` | (empty) |
| `face` | `face_id` |
| `reply` | `message_seq` |
| `image` | `resource_id`, `temp_url`, `width`, `height`, `summary`, `sub_type` |
| `record` | `resource_id`, `temp_url`, `duration` |
| `video` | `resource_id`, `temp_url`, `width`, `height`, `duration` |
| `file` | `file_id`, `file_name`, `file_size`, `file_hash?` |
| `forward` | `forward_id` |
| `market_face` | `url` |
| `light_app` | `app_name`, `json_payload` |
| `xml` | `service_id`, `xml_payload` |

### Outgoing (sent to QQ server)

| type | Data fields | Notes |
|------|------------|-------|
| `text` | `text` | Required |
| `mention` | `user_id` | Required |
| `mention_all` | (empty) | |
| `face` | `face_id` | Required |
| `reply` | `message_seq` | Required |
| `image` | `uri`, `summary?`, `sub_type` | Required |
| `record` | `uri` | Required |
| `video` | `uri`, `thumb_uri?` | Required |
| `forward` | `messages[]` | Array of `{user_id, sender_name, segments[]}` |
| `light_app` | `json_payload` | Required |

---

## Entity Types

### Group
```
{group_id, group_name, member_count, max_member_count}
```

### GroupMember
```
{user_id, nickname, sex, group_id, card, title, level, role, join_time, last_sent_time, shut_up_end_time?}
```

### Friend
```
{user_id, nickname, sex, qid, remark, category: {category_id, category_name}}
```

### MessageBase
```
{peer_id, message_seq, sender_id, time, segments[], message_scene}
```
- `message_scene`: `"friend"`, `"group"`, or `"temp"`
- GroupMessage adds: `group`, `group_member`
- FriendMessage adds: `friend`
- TempMessage adds: `group` (nullable)

### GroupNotificationBase
```
{type, group_id, notification_seq}
```
Types: `join_request`, `invited_join_request`, `admin_change`, `kick`, `quit`
