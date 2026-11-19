# test/test_router_route.sh — router.sh 路由判定
# 目标：路径段是唯一权威；?platform= 仅在路径缺失时兜底；未知路径一律 404，
# 不再默认落到 qq（默认分支会让裸 /cgi-bin/router.sh?token=xxx 误入 qq）。

# _route_head <uri> <query> [extra env...] → 首响应行
_route_head() {
	_uri="$1" _qs="$2"
	shift 2
	printf '' | env -i \
		REQUEST_METHOD=POST \
		REQUEST_URI="$_uri" \
		QUERY_STRING="$_qs" \
		CONTENT_LENGTH=0 \
		WEBHOOK_SECRET=realsecret \
		QQBOT_WEBHOOK_TOKEN=qqonly \
		FNOS_WEBHOOK_TOKEN=fnosonly \
		PATH=/usr/bin:/bin \
		HTTP_X_TEST=1 \
		"$@" \
		sh ./cgi-bin/router.sh 2>/dev/null | head -1 | tr -d '\r'
}

_route_body() {
	_uri="$1" _qs="$2"
	shift 2
	printf '' | env -i \
		REQUEST_METHOD=POST \
		REQUEST_URI="$_uri" \
		QUERY_STRING="$_qs" \
		CONTENT_LENGTH=0 \
		WEBHOOK_SECRET=realsecret \
		QQBOT_WEBHOOK_TOKEN=qqonly \
		FNOS_WEBHOOK_TOKEN=fnosonly \
		PATH=/usr/bin:/bin \
		"$@" \
		sh ./cgi-bin/router.sh 2>/dev/null | tail -1
}

test_route_unknown_path_is_404() {
	assert_eq "$(_route_head /cgi-bin/router.sh/whatever '')" \
		'Status: 404 Not Found' "未知平台路径必须 404，不得默认 qq"
}

test_route_unknown_body_json() {
	assert_contains "$(_route_body /cgi-bin/router.sh/whatever '')" \
		'unknown platform' "404 响应体应包含 error=unknown platform"
}

test_route_near_miss_path_is_404() {
	assert_eq "$(_route_head /cgi-bin/router.sh/qqbotx '')" \
		'Status: 404 Not Found' "/qqbotx 不得被前缀匹配成 qqbot"
}

test_route_bare_entry_no_longer_defaults_qq() {
	assert_eq "$(_route_head /cgi-bin/router.sh 'token=realsecret')" \
		'Status: 404 Not Found' "裸 entry 携带全局 token 也不得默认 qq"
}

test_route_legacy_switch_restores_qq() {
	assert_eq "$(_route_head /cgi-bin/router.sh 'token=realsecret' ROUTER_DEFAULT_PLATFORM=qq)" \
		'Status: 200 OK' "ROUTER_DEFAULT_PLATFORM=qq 时应落到 qq 并正常分发"
}

test_route_legacy_switch_ignores_bad_value() {
	assert_eq "$(_route_head /cgi-bin/router.sh 'token=realsecret' ROUTER_DEFAULT_PLATFORM=../../etc/passwd)" \
		'Status: 404 Not Found' "非法 ROUTER_DEFAULT_PLATFORM 必须忽略"
}

test_route_query_fallback_qqbot() {
	# 代理吃掉路径段时，?platform=qqbot 仍能识别：识别成功走鉴权 → 403（而非 404）
	assert_eq "$(_route_head /cgi-bin/router.sh 'platform=qqbot')" \
		'Status: 403 Forbidden' "?platform=qqbot 兜底应识别出 qqbot 并进入鉴权"
}

test_route_query_fallback_exact_match() {
	# ?platform=qq 不得被 *platform=qqbot* 误匹配
	assert_eq "$(_route_head /cgi-bin/router.sh 'platform=qq&x=1')" \
		'Status: 403 Forbidden' "?platform=qq 必须精确匹配 qq"
}

test_route_path_wins_over_query() {
	# 路径 /fnos 与 query platform=qqbot 冲突时，路径优先
	_out="$(_route_head /cgi-bin/router.sh/fnos 'platform=qqbot')"
	assert_eq "$_out" 'Status: 403 Forbidden' "路径优先于 query 兜底"
}

test_route_fnos_known() {
	assert_eq "$(_route_head /cgi-bin/router.sh/fnos '')" \
		'Status: 403 Forbidden' "fnos 平台应被识别（未带 token → 403 而非 404）"
}

test_route_qqbot_path_with_alt_token() {
	# qqbot 端点自带 token 应解锁（不再 403）
	_out="$(_route_head /cgi-bin/router.sh/qqbot 'token=qqonly')"
	# 鉴权已过 → 进入分发；空 body 由 qqbot 适配器判为 400（关键是不再 403/404）
	assert_eq "$_out" 'Status: 400 Bad Request' "qqbot 端点接受 QQBOT_WEBHOOK_TOKEN"
}

test_route_unknown_path_is_404
test_route_unknown_body_json
test_route_near_miss_path_is_404
test_route_bare_entry_no_longer_defaults_qq
test_route_legacy_switch_restores_qq
test_route_legacy_switch_ignores_bad_value
test_route_query_fallback_qqbot
test_route_query_fallback_exact_match
test_route_path_wins_over_query
test_route_fnos_known
test_route_qqbot_path_with_alt_token
