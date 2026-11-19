# adapter/qqbot/richtext.sh — text-chain tags (outbound builders + inbound render)
#
# QQ 群/单聊 text 消息支持一组"文本交互"标签（server-inter/message/trans）：
#   <qqbot-at-user id="OPENID" />          at 某人（群聊：member_openid；单聊：user_openid）
#   <qqbot-at-everyone />                  at 全体成员（群主/管理员）
#   <qqbot-cmd-enter text="..." />         把指令插入输入框并直接发送（≤100 字符，text 需 urlencode）
#   <qqbot-cmd-input text="..." show="..." reference="true" />
#                                          把指令插入输入框但不发送；show 为展示文案
#   <#channel_id>                          子频道跳转（频道场景）
#   <emoji:id>                             频道表情
# 入站 content 是 markdown 风格：<@OPENID> / <@!OPENID> at，<faceType=..,ext="base64">
# 表情，以及上面这组标签（可能被 HTML 转义成 \u003c...\u003e，调用前先 utf8_decode）。

[ "${_QQBOT_RICHTEXT_SH:-0}" = "1" ] && return 0
_QQBOT_RICHTEXT_SH=1

# ---- outbound builders --------------------------------------------------

# ---- percent codec (UTF-8 safe) -----------------------------------------
#
# lib/url.sh's url_encode/url_decode only know ASCII: a Chinese command would go
# out as raw bytes (the client then shows mojibake and the documented
# "传值时需要 urlencode" contract is violated). These two work on bytes:
#   _qqbot_pct_encode <text>  every byte except A-Za-z0-9-_.~ → %XX
#   _qqbot_pct_decode <%XX..> any %XX → its byte, UTF-8 sequences reassemble
_qqbot_pct_encode() {
	printf '%s' "$1" | od -An -v -tu1 | tr -s ' ' '\n' | while IFS= read -r _pe_b; do
		[ -n "$_pe_b" ] || continue
		case "$_pe_b" in
			45|46|48|49|50|51|52|53|54|55|56|57|65|66|67|68|69|70|71|72|73|74|75|76|77|78|79|80|81|82|83|84|85|86|87|88|89|90|95|97|98|99|100|101|102|103|104|105|106|107|108|109|110|111|112|113|114|115|116|117|118|119|120|121|122|126)
				printf "\\$(printf '%03o' "$_pe_b")" ;;
			*) printf '%%%02X' "$_pe_b" ;;
		esac
	done
}

_qqbot_pct_decode() {
	_pd_s="$1" _pd_o=""
	while [ -n "$_pd_s" ]; do
		case "$_pd_s" in
			%[0-9A-Fa-f][0-9A-Fa-f]*)
				_pd_h="$(printf '%s' "$_pd_s" | cut -c2-3)"
				_pd_o="$_pd_o$(printf "\\$(printf '%03o' "$((0x$_pd_h))")")"
				_pd_s="$(printf '%s' "$_pd_s" | cut -c4-)" ;;
			*) _pd_o="$_pd_o$(printf '%s' "$_pd_s" | cut -c1)"
			   _pd_s="$(printf '%s' "$_pd_s" | cut -c2-)" ;;
		esac
	done
	printf '%s' "$_pd_o"
}

# qqbot_tag_at <openid>
qqbot_tag_at() { printf '<qqbot-at-user id="%s" />' "$1"; }

qqbot_tag_at_everyone() { printf '<qqbot-at-everyone />'; }

# qqbot_tag_cmd_enter <text> — 直接发送（≤100 字符，群聊/文字子频道不支持）
qqbot_tag_cmd_enter() { printf '<qqbot-cmd-enter text="%s" />' "$(_qqbot_pct_encode "$1")"; }

# qqbot_tag_cmd_input <text> [show] [reference]
qqbot_tag_cmd_input() {
	_qti_out="<qqbot-cmd-input text=\"$(_qqbot_pct_encode "$1")\""
	[ -n "${2:-}" ] && _qti_out="$_qti_out show=\"$(_qqbot_pct_encode "$2")\""
	[ "${3:-false}" = "true" ] && _qti_out="$_qti_out reference=\"true\""
	printf '%s />' "$_qti_out"
}

# qqbot_tag_channel <channel_id> / qqbot_tag_emoji <emoji_id>
qqbot_tag_channel() { printf '<#%s>' "$1"; }
qqbot_tag_emoji()   { printf '<emoji:%s>' "$1"; }

# ---- inline keyboard (msg_type=0/2/7/8 均可挂) --------------------------
#
# 结构（官方 MessageCard/Keyboard）：
#   {"content":{"rows":[{"buttons":[{id,render_data,action,group_id}...]}...]}}
# 或者用平台预设模板：{"id":"<template_id>"}（见 qqbot_body_keyboard）

# _qqbot_chars <text> — 字符数（中文按 1 个算，官方限制都按字符不按字节）
_qqbot_chars() { printf '%s' "$1" | wc -m | tr -d ' '; }

# _qqbot_jseg <seg> <key> <raw_json_value> → "seg,\"key\":value"
_qqbot_jseg() {
	case "$1" in
		"") printf '"%s":%s' "$2" "$3" ;;
		*)  printf '%s,"%s":%s' "$1" "$2" "$3" ;;
	esac
}

# qqbot_kbd_action <type> [flags] → action 对象
#   type 0=跳转(未实现 url 跳转字段, 仅透传) 1=回调 2=指令
#   --data D            回调/指令数据（type=1/2 必填）
#   --perm 0|1|2        0 指定用户 / 1 管理员 / 2 所有人（默认 2）
#   --users '["id"]'    permission.specify_user_ids（原样 JSON 数组）
#   --roles '["id"]'    permission.specify_role_ids（原样 JSON 数组，仅频道）
#   --tips T            unsupport_tips
#   --enter / --reply   指令按钮：是否直接发送 / 是否带引用（版本 8983+）
#   --anchor N          action.anchor（1=唤起选图器，仅手机单聊）
#   --show-channel-list 0|1  at_bot_show_channel_list（互动概述里出现，01 页未列）
#   --click-limit N     click_limit（已废弃，仅透传）
#   --modal TEXT [--confirm T] [--cancel T]  二次确认弹窗（≤40 字，不能带 URL）
qqbot_kbd_action() {
	_ka_t="$1"; shift
	_ka_data="" _ka_perm=2 _ka_users="" _ka_roles="" _ka_tips="" _ka_enter="" _ka_reply=""
	_ka_anchor="" _ka_limit="" _ka_show="" _ka_modal="" _ka_confirm="" _ka_cancel=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--data) _ka_data="$2"; shift 2 ;;
			--perm) _ka_perm="$2"; shift 2 ;;
			--users) _ka_users="$2"; shift 2 ;;
			--roles) _ka_roles="$2"; shift 2 ;;
			--tips) _ka_tips="$2"; shift 2 ;;
			--enter) _ka_enter=true; shift ;;
			--reply) _ka_reply=true; shift ;;
			--anchor) _ka_anchor="$2"; shift 2 ;;
			--show-channel-list) _ka_show="$2"; shift 2 ;;
			--click-limit) _ka_limit="$2"; shift 2 ;;
			--modal) _ka_modal="$2"; shift 2 ;;
			--confirm) _ka_confirm="$2"; shift 2 ;;
			--cancel) _ka_cancel="$2"; shift 2 ;;
			*) _ERROR="qqbot.kbd.action: unknown option $1"; return 1 ;;
		esac
	done
	case "$_ka_perm" in 0|1|2) ;; *) _ERROR="qqbot.kbd.action: --perm must be 0/1/2"; return 1 ;; esac
	if [ "$_ka_t" = "1" ] || [ "$_ka_t" = "2" ]; then
		[ -n "$_ka_data" ] || { _ERROR="qqbot.kbd.action: --data required for type=$_ka_t"; return 1; }
	fi
	# permission 对象
	_ka_po="$(_qqbot_jseg "" type "$_ka_perm")"
	[ -n "$_ka_users" ] && _ka_po="$(_qqbot_jseg "$_ka_po" specify_user_ids "$_ka_users")"
	[ -n "$_ka_roles" ] && _ka_po="$(_qqbot_jseg "$_ka_po" specify_role_ids "$_ka_roles")"

	_ka_s="$(_qqbot_jseg "" type "$_ka_t")"
	_ka_s="$(_qqbot_jseg "$_ka_s" permission "{$_ka_po}")"
	[ -n "$_ka_data" ] && _ka_s="$(_qqbot_jseg "$_ka_s" data "$(json_escape "$_ka_data")")"
	[ -n "$_ka_limit" ] && _ka_s="$(_qqbot_jseg "$_ka_s" click_limit "$_ka_limit")"
	[ -n "$_ka_tips" ] && _ka_s="$(_qqbot_jseg "$_ka_s" unsupport_tips "$(json_escape "$_ka_tips")")"
	[ -n "$_ka_enter" ] && _ka_s="$(_qqbot_jseg "$_ka_s" enter true)"
	[ -n "$_ka_reply" ] && _ka_s="$(_qqbot_jseg "$_ka_s" reply true)"
	[ -n "$_ka_anchor" ] && _ka_s="$(_qqbot_jseg "$_ka_s" anchor "$_ka_anchor")"
	[ -n "$_ka_show" ] && _ka_s="$(_qqbot_jseg "$_ka_s" at_bot_show_channel_list "$_ka_show")"
	if [ -n "$_ka_modal" ]; then
		[ "$(_qqbot_chars "$_ka_modal")" -le 40 ] || { _ERROR="qqbot.kbd.action: --modal max 40 chars"; return 1; }
		_ka_mo="$(_qqbot_jseg "" content "$(json_escape "$_ka_modal")")"
		[ -n "$_ka_confirm" ] && _ka_mo="$(_qqbot_jseg "$_ka_mo" confirm_text "$(json_escape "$_ka_confirm")")"
		[ -n "$_ka_cancel" ] && _ka_mo="$(_qqbot_jseg "$_ka_mo" cancel_text "$(json_escape "$_ka_cancel")")"
		_ka_s="$(_qqbot_jseg "$_ka_s" modal "{$_ka_mo}")"
	fi
	printf '{%s}' "$_ka_s"
}

# qqbot_kbd_button <id> <label> <action_json> [--visited L] [--style 0|1|3|4] [--group G] [--label-max]
qqbot_kbd_button() {
	_kb_id="$1" _kb_label="$2" _kb_action="$3"; shift 3
	_kb_visited="" _kb_style=1 _kb_group=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--visited) _kb_visited="$2"; shift 2 ;;
			--style) _kb_style="$2"; shift 2 ;;
			--group) _kb_group="$2"; shift 2 ;;
			*) _ERROR="qqbot.kbd.button: unknown option $1"; return 1 ;;
		esac
	done
	# 官方限制：label 最多 10 字符（按字符数，不是字节）
	[ "$(_qqbot_chars "$_kb_label")" -le 10 ] || { _ERROR="qqbot.kbd.button: label max 10 chars"; return 1; }
	[ "$(_qqbot_chars "${_kb_visited:-}")" -le 10 ] || { _ERROR="qqbot.kbd.button: visited label max 10 chars"; return 1; }
	_kb_rd="$(_qqbot_jseg "" label "$(json_escape "$_kb_label")")"
	_kb_rd="$(_qqbot_jseg "$_kb_rd" visited_label "$(json_escape "${_kb_visited:-$_kb_label}")")"
	_kb_rd="$(_qqbot_jseg "$_kb_rd" style "${_kb_style:-1}")"
	_kb_s="$(_qqbot_jseg "" id "$(json_escape "$_kb_id")")"
	_kb_s="$(_qqbot_jseg "$_kb_s" render_data "{$_kb_rd}")"
	_kb_s="$(_qqbot_jseg "$_kb_s" action "$_kb_action")"
	[ -n "$_kb_group" ] && _kb_s="$(_qqbot_jseg "$_kb_s" group_id "$(json_escape "$_kb_group")")"
	printf '{%s}' "$_kb_s"
}

# qqbot_kbd_row <button_json...> → {"buttons":[...]}
qqbot_kbd_row() {
	_kr_out=""
	for _kr_b in "$@"; do _kr_out="${_kr_out:+$_kr_out,}$_kr_b"; done
	printf '{"buttons":[%s]}' "$_kr_out"
}

# qqbot_kbd_rows <row_json...> → rows 数组（喂给 qqbot_msg_send 的 --keyboard-rows）
qqbot_kbd_rows() {
	_krs_out=""
	for _krs_r in "$@"; do _krs_out="${_krs_out:+$_krs_out,}$_krs_r"; done
	printf '[%s]' "$_krs_out"
}

# qqbot_kbd_custom <row_json...> → 完整 keyboard 对象（喂给 --keyboard-json）
qqbot_kbd_custom() {
	_kc_out=""
	for _kc_r in "$@"; do _kc_out="${_kc_out:+$_kc_out,}$_kc_r"; done
	printf '{"content":{"rows":[%s]}}' "$_kc_out"
}

# ---- ARK 结构化卡片 msg_type=3 ------------------------------------------
# 官方 §2 未给出 ark 字段定义，§3 只在“发送侧 0/2/3/7”里出现过 3；
# 结构与频道侧一致：{"template_id": <int>, "kv": [{"key":"#XXX#","value":"..."}]}
# qqbot_ark_kv <key> <value> → kv 条目
qqbot_ark_kv() {
	[ $# -ge 2 ] || { _ERROR="qqbot.ark.kv: <key> <value>"; return 1; }
	printf '{"key":%s,"value":%s}' "$(json_escape "$1")" "$(json_escape "$2")"
}

# qqbot_ark <template_id> [kv_item...] → ark 对象（喂给 --ark）
qqbot_ark() {
	case "$1" in '') _ERROR="qqbot.ark: <template_id> required"; return 1 ;; esac
	case "$1" in *[!0-9]*) _ERROR="qqbot.ark: template_id must be integer"; return 1 ;; esac
	_ar_tpl="$1"; shift
	_ar_kv=""
	for _ar_i in "$@"; do _ar_kv="${_ar_kv:+$_ar_kv,}$_ar_i"; done
	printf '{"template_id":%s,"kv":[%s]}' "$_ar_tpl" "$_ar_kv"
}

# qqbot_render_ark <ark_data_json> — 入站结构化卡片降级为可读文本
# 依次取 kv[].value（跳过空值），用 " | " 连接；失败返回空串
qqbot_render_ark() {
	[ -n "$1" ] || return 0
	_ra_out=""
	_ra_vals="$(printf '%s' "$1" | grep -o '"value"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"//; s/"$//')"
	OLDIFS=$IFS; IFS='
'
	for _ra_v in $_ra_vals; do
		[ -n "$_ra_v" ] || continue
		case "$_ra_v" in *'"'*|*'\'*) _ra_v="$(utf8_decode "$_ra_v")" ;; esac
		_ra_out="${_ra_out:+$_ra_out | }$_ra_v"
	done
	IFS=$OLDIFS
	printf '%s' "$_ra_out"
}

# qqbot_render_msg_elements <msg_elements_json> — 入站引用消息(message_type=103)
# 把嵌套的 msg_elements[].content 依次摊平，去掉空值，用 " | " 连接
qqbot_render_msg_elements() {
	[ -n "$1" ] || return 0
	_me_out=""
	_me_vals="$(printf '%s' "$1" | grep -o '"content"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"//; s/"$//')"
	OLDIFS=$IFS; IFS='
'
	for _me_v in $_me_vals; do
		[ -n "$_me_v" ] || continue
		_me_out="${_me_out:+$_me_out | }$_me_v"
	done
	IFS=$OLDIFS
	printf '%s' "$_me_out"
}

# ---- 图文卡片 msg_type=8 (type=tuwen) -----------------------------------
# qqbot_card_tuwen <title> <description> <url> <pic_url>
#   官方长度限制：title 1-50，description 1-200，url/pic_url 必须 https 且 ≤1024
qqbot_card_tuwen() {
	[ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || {
		_ERROR="qqbot.card.tuwen: title, description, url, pic_url are required"; return 1; }
	[ "$(_qqbot_chars "$1")" -le 50 ] || { _ERROR="qqbot.card.tuwen: title max 50 chars"; return 1; }
	[ "$(_qqbot_chars "$2")" -le 200 ] || { _ERROR="qqbot.card.tuwen: description max 200 chars"; return 1; }
	case "$3" in https://*) ;; *) _ERROR="qqbot.card.tuwen: url must be https"; return 1 ;; esac
	case "$4" in https://*) ;; *) _ERROR="qqbot.card.tuwen: pic_url must be https"; return 1 ;; esac
	[ "${#3}" -le 1024 ] || { _ERROR="qqbot.card.tuwen: url max 1024 chars"; return 1; }
	[ "${#4}" -le 1024 ] || { _ERROR="qqbot.card.tuwen: pic_url max 1024 chars"; return 1; }
	_ct_c="$(_qqbot_jseg "" title "$(json_escape "$1")")"
	_ct_c="$(_qqbot_jseg "$_ct_c" description "$(json_escape "$2")")"
	_ct_c="$(_qqbot_jseg "$_ct_c" url "$(json_escape "$3")")"
	_ct_c="$(_qqbot_jseg "$_ct_c" pic_url "$(json_escape "$4")")"
	printf '{"type":"tuwen","content":{%s}}' "$_ct_c"
}

# qqbot_md_image <url> [alt] [width_px] [height_px]
# Markdown 图片，宽高写法为 `#800px` 后缀
qqbot_md_image() {
	_qmi_alt="${2:-}"
	_qmi_sz=""
	[ -n "${3:-}" ] && _qmi_sz=" #${3}px"
	[ -n "${4:-}" ] && _qmi_sz="$_qmi_sz #${4}px"
	printf '![%s%s](%s)' "$_qmi_alt" "$_qmi_sz" "$1"
}

# ---- inbound helpers ----------------------------------------------------

# _qqbot_tag_attr <tag> <name> → attribute value ("" when absent)
_qqbot_tag_attr() {
	printf '%s' "$1" | sed -n 's/.*'"$2"'="\([^"]*\)".*/\1/p'
}

# _qqbot_lit_rep <text> <literal> <replacement>
# Literal, newline-preserving replacement: tags carry ids and urldecoded text
# that must never be read as a sed pattern.
_qqbot_lit_rep() {
	printf '%s' "$1" | awk -v n="$2" -v l="$3" '
		{ if (NR > 1) printf "\n"
		  s = $0; o = ""
		  while ((i = index(s, n)) > 0) {
			o = o substr(s, 1, i - 1) l
			s = substr(s, i + length(n))
		  }
		  printf "%s%s", o, s }'
}

# _qqbot_sed_rep <text> <literal> <replacement> — same but single-line, regex-free
_qqbot_sed_rep() { _qqbot_lit_rep "$1" "$2" "$3"; }

# _qqbot_nick_or_id <group_openid> <openid> → @nick | @qq#<first7>
_qqbot_nick_or_id() {
	_qni_n=""
	[ -n "${1:-}" ] && _qni_n="$(qqbot_nick_auto_get "$1" "$2")"
	if [ -n "$_qni_n" ]; then
		printf '@%s' "$_qni_n"
	else
		printf '@qq#%s' "$(printf '%s' "$2" | cut -c1-7)"
	fi
}

# ---- inbound rendering --------------------------------------------------

# qqbot_render_content <text> [group_openid]
# Renders every inbound tag shape into readable text:
#   <qqbot-at-user id=X>            → @nick / @qq#<first7>
#   <qqbot-at-everyone />           → @全体成员
#   <qqbot-cmd-enter text=X>        → /<urldecoded X>
#   <qqbot-cmd-input text=X show=Y> → Y (or urldecoded X)
#   <#id>                           → #id        <emoji:id> → [emoji:id]
#   <faceType=..,ext="b64">         → decoded ext.text
#   <@OPENID> / <@!OPENID>          → @nick / @qq#<first7>
#
# Tags are extracted to a temp file and consumed with `while read`, so a tag
# containing spaces is never word-split and the loop still runs in this shell
# (a pipe would make every replacement vanish with the subshell).
qqbot_render_content() {
	_qrc_t="$1" _qrc_gid="$2"
	_qrc_tf="/tmp/qqbot-tags.$$"
	: >"$_qrc_tf" 2>/dev/null

	# ---- text-chain: <qqbot-at-user id="..." /> ----
	printf '%s' "$_qrc_t" | grep -o '<qqbot-at-user[^>]*>' | sort -u >"$_qrc_tf"
	while IFS= read -r _qrc_tag; do
		_qrc_o="$(_qqbot_tag_attr "$_qrc_tag" id)"
		[ -n "$_qrc_o" ] || continue
		_qrc_t="$(_qqbot_lit_rep "$_qrc_t" "$_qrc_tag" "$(_qqbot_nick_or_id "$_qrc_gid" "$_qrc_o")")"
	done <"$_qrc_tf"
	_qrc_t="$(_qqbot_lit_rep "$_qrc_t" '<qqbot-at-everyone />' '@全体成员')"

	# ---- text-chain: cmd-enter / cmd-input ----
	# 客户端展示的 "/指令" 前缀由 QQ 自己加，text 里不会再带，所以这里只还原
	# 文本本体（UTF-8 百分号解码），加斜杠会渲染成 "//历史"。
	printf '%s' "$_qrc_t" | grep -o '<qqbot-cmd-enter[^>]*>' | sort -u >"$_qrc_tf"
	while IFS= read -r _qrc_tag; do
		_qrc_v="$(_qqbot_tag_attr "$_qrc_tag" text)"
		[ -n "$_qrc_v" ] || continue
		_qrc_t="$(_qqbot_lit_rep "$_qrc_t" "$_qrc_tag" "$(_qqbot_pct_decode "$_qrc_v")")"
	done <"$_qrc_tf"
	printf '%s' "$_qrc_t" | grep -o '<qqbot-cmd-input[^>]*>' | sort -u >"$_qrc_tf"
	while IFS= read -r _qrc_tag; do
		_qrc_v="$(_qqbot_tag_attr "$_qrc_tag" show)"
		[ -n "$_qrc_v" ] || _qrc_v="$(_qqbot_tag_attr "$_qrc_tag" text)"
		[ -n "$_qrc_v" ] || continue
		_qrc_t="$(_qqbot_lit_rep "$_qrc_t" "$_qrc_tag" "$(_qqbot_pct_decode "$_qrc_v")")"
	done <"$_qrc_tf"

	# ---- markdown mentions <@OPENID> / <@!OPENID> ----
	printf '%s' "$_qrc_t" | grep -o '<@[A-Za-z0-9!]\{8,\}>' | sort -u >"$_qrc_tf"
	while IFS= read -r _qrc_tag; do
		_qrc_o="$(printf '%s' "$_qrc_tag" | sed 's/^<@//; s/>$//; s/^!//')"
		[ -n "$_qrc_o" ] || continue
		_qrc_t="$(_qqbot_lit_rep "$_qrc_t" "$_qrc_tag" "$(_qqbot_nick_or_id "$_qrc_gid" "$_qrc_o")")"
	done <"$_qrc_tf"

	# ---- faces <faceType=4,faceId="",ext="<base64 json>"> ----
	# ext decodes to {"text":"[聪明]"}; faceId is empty for most faces.
	printf '%s' "$_qrc_t" | grep -o 'ext="[A-Za-z0-9+/=]\{4,\}"' | sed 's/^ext="//; s/"$//' | sort -u >"$_qrc_tf"
	while IFS= read -r _qrc_b; do
		_qrc_x="$(printf '%s' "$_qrc_b" | base64 -d 2>/dev/null | sed 's/.*"text":"//; s/"}.*//' | tr -d '\n')"
		[ -n "$_qrc_x" ] || continue
		_qrc_lit="ext=\"$_qrc_b\""
		printf '%s' "$_qrc_t" | grep -o "<faceType=[^>]*$_qrc_lit[^>]*>" | sort -u >"$_qrc_tf.2"
		while IFS= read -r _qrc_tag; do
			_qrc_t="$(_qqbot_lit_rep "$_qrc_t" "$_qrc_tag" "$_qrc_x")"
		done <"$_qrc_tf.2"
	done <"$_qrc_tf"
	rm -f "$_qrc_tf.2"

	# ---- channel / emoji tags keep their ids ----
	printf '%s' "$_qrc_t" | grep -o '<#[A-Za-z0-9_-]\{1,\}>' | sort -u >"$_qrc_tf"
	while IFS= read -r _qrc_tag; do
		_qrc_id="$(printf '%s' "$_qrc_tag" | sed 's/^<#//; s/>$//')"
		_qrc_t="$(_qqbot_lit_rep "$_qrc_t" "$_qrc_tag" "#$_qrc_id")"
	done <"$_qrc_tf"
	printf '%s' "$_qrc_t" | grep -o '<emoji:[A-Za-z0-9_]\{1,\}>' | sort -u >"$_qrc_tf"
	while IFS= read -r _qrc_tag; do
		_qrc_id="$(printf '%s' "$_qrc_tag" | sed 's/^<emoji://; s/>$//')"
		_qrc_t="$(_qqbot_lit_rep "$_qrc_t" "$_qrc_tag" "[emoji:$_qrc_id]")"
	done <"$_qrc_tf"

	# ---- leftovers: drop any tag shape not handled above ----
	_qrc_t="$(printf '%s' "$_qrc_t" | sed 's|<faceType=[^>]*>||g; s|<@[A-Za-z0-9!]\{8,\}>||g; s|<qqbot-[a-z-]*[^>]*>||g')"
	rm -f "$_qrc_tf"
	printf '%s' "$_qrc_t"
}
