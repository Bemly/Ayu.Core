#!/bin/sh

# Standalone suite: run it directly. test/run.sh sources this file, which would
# clobber its PASS/FAIL counters, so bail out when sourced.
if [ "${_AYU_TEST_SOURCED:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# Local verification for the notify gateway (no network: MOCK_HTTP=1).
# Run from the repo root: sh test/test_notify.sh  (NOTIFY_TREE overrides the target)
SELF=$(cd "$(dirname "$0")" && pwd)
B=$(cd "$SELF/.." && pwd)
if [ -n "${NOTIFY_TREE:-}" ]; then T=$NOTIFY_TREE
elif [ -d "$B/output/notify-tree" ]; then T=$B/output/notify-tree
else T=$B
fi
WORK=$B/temp/testwork
rm -rf "$WORK" 2>/dev/null
mkdir -p "$WORK" "$T/var/state"
# pre-seed the QQ access_token cache (otherwise the gateway calls
# getAppAccessToken first and one mock reply cannot satisfy both calls)
printf '{"access_token":"mock-token","expires_at":%s}' "$(( $(date +%s) + 3600 ))" >"$T/var/state/qqbot-token.json"
rm -rf "$T/var/state/notify-cb"; mkdir -p "$T/var/state/notify-cb"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

cgi() { # cgi <body> <mock_response>
	printf '%s' "$1" | env \
		REQUEST_METHOD=POST PATH_INFO=/notify \
		REQUEST_URI=/cgi-bin/router.sh/notify \
		QUERY_STRING='token=notifysecret' \
		CONTENT_TYPE=application/json \
		CONTENT_LENGTH="$(printf '%s' "$1" | wc -c | tr -d ' ')" \
		AYU_ENV=dev NOTIFY_WEBHOOK_TOKEN=notifysecret \
		MOCK_HTTP=1 MOCK_LOG="$WORK/http.log" \
		MOCK_RESPONSE="${2:-{\}}" \
		sh "$T/cgi-bin/router.sh"
}

RELAY() { # RELAY <script args...>
	env MOCK_HTTP=1 MOCK_LOG="$WORK/relay-http.log" MOCK_RESPONSE='{}' \
		sh "$WORK/relay.sh" "$@"
}

echo "== A1. qqbot: keyboard rows + relay key =="
: >"$WORK/http.log"
OUT=$(cgi '{"to":["qqbot:group:G1"],"text":"构建 #123 失败","buttons":[{"id":"retry","label":"重试","data":"action=retry&run=123"}],"callback":"https://ci.example.com/hook/result"}' '{"id":"m1","timestamp":"2026-11-20T00:00:00+08:00"}')
case "$OUT" in *'"ok":true,"sent":1'*) ok "qqbot sent=1" ;; *) bad "qqbot sent=1" "$(printf '%s' "$OUT" | tail -1)" ;; esac
grep -q 'keyboard' "$WORK/http.log" && ok "keyboard object present" || bad "keyboard object" ""
grep -q 'render_data' "$WORK/http.log" && ok "button render_data present" || bad "render_data" ""
grep -q '_k=' "$WORK/http.log" && ok "relay key injected" || bad "relay key injected" ""
grep -q "/v2/groups/G1/messages" "$WORK/http.log" && ok "group endpoint" || bad "group endpoint" "$(head -3 "$WORK/http.log")"

echo "== A2. telegram: inline_keyboard + callback_data =="
: >"$WORK/http.log"
OUT=$(cgi '{"to":["telegram:chat:100"],"text":"t","buttons":[{"id":"retry","label":"重试","data":"action=retry"}]}' '{"ok":true,"result":{"message_id":1}}')
case "$OUT" in *'"sent":1'*) ok "telegram sent=1" ;; *) bad "telegram sent=1" "$(printf '%s' "$OUT" | tail -1)" ;; esac
grep -q 'inline_keyboard' "$WORK/http.log" && ok "inline_keyboard built" || bad "inline_keyboard" ""
grep -q 'callback_data' "$WORK/http.log" && ok "callback_data built" || bad "callback_data" ""
grep -q 'reply_markup' "$WORK/http.log" && ok "reply_markup attached" || bad "reply_markup" ""

echo "== A3. discord: components + custom_id =="
: >"$WORK/http.log"
OUT=$(cgi '{"to":["discord:channel:200"],"text":"t","buttons":[{"id":"retry","label":"重试","data":"action=retry"}]}' '{"id":"m1","channel_id":"200"}')
case "$OUT" in *'"sent":1'*) ok "discord sent=1" ;; *) bad "discord sent=1" "$(printf '%s' "$OUT" | tail -1)" ;; esac
grep -q 'components' "$WORK/http.log" && ok "components built" || bad "components" ""
grep -q 'custom_id' "$WORK/http.log" && ok "custom_id built" || bad "custom_id" ""

echo "== A4. partial failure isolation =="
: >"$WORK/http.log"
OUT=$(cgi '{"to":["qqbot:group:G1","telegram:chat:100","discord:channel:200"],"text":"t"}' '{"id":"m1"}')
case "$OUT" in *'"sent":2,"failed":1'*) ok "one bad target does not block the rest" ;; *) bad "partial isolation" "$(printf '%s' "$OUT" | tail -1)" ;; esac

echo "== B. SSRF guard =="
for u in http://127.0.0.1/x http://10.0.0.5/h http://192.168.1.2/y http://172.16.4.4/z http://169.254.169.254/latest ftp://ci.example.com/x file:///etc/passwd; do
	OUT=$(cgi "{\"to\":[\"telegram:chat:1\"],\"text\":\"t\",\"callback\":\"$u\"}" '{"ok":true,"result":{}}')
	case "$OUT" in *rejected*) ok "rejected $u" ;; *) bad "rejected $u" "$(printf '%s' "$OUT" | tail -1)" ;; esac
done
OUT=$(cgi '{"to":[],"text":"t","callback":"https://ci.example.com/ok"}' '{}')
case "$OUT" in *'"ok":true'*) ok "public callback allowed" ;; *) bad "public callback allowed" "$(printf '%s' "$OUT" | tail -1)" ;; esac

echo "== B2. host allowlist =="
OUT=$(printf '%s' '{"to":[],"text":"t","callback":"https://evil.example.net/x"}' | env \
	REQUEST_METHOD=POST PATH_INFO=/notify REQUEST_URI=/cgi-bin/router.sh/notify \
	QUERY_STRING='token=notifysecret' CONTENT_LENGTH=60 AYU_ENV=dev \
	NOTIFY_WEBHOOK_TOKEN=notifysecret NOTIFY_ALLOW_HOSTS="ci.example.com" \
	sh "$T/cgi-bin/router.sh")
case "$OUT" in *rejected*) ok "host outside allowlist rejected" ;; *) bad "allowlist reject" "$(printf '%s' "$OUT" | tail -1)" ;; esac
OUT=$(printf '%s' '{"to":[],"text":"t","callback":"https://ci.example.com/x"}' | env \
	REQUEST_METHOD=POST PATH_INFO=/notify REQUEST_URI=/cgi-bin/router.sh/notify \
	QUERY_STRING='token=notifysecret' CONTENT_LENGTH=58 AYU_ENV=dev \
	NOTIFY_WEBHOOK_TOKEN=notifysecret NOTIFY_ALLOW_HOSTS="ci.example.com" \
	sh "$T/cgi-bin/router.sh")
case "$OUT" in *'"ok":true'*) ok "allowlisted host accepted" ;; *) bad "allowlist accept" "$(printf '%s' "$OUT" | tail -1)" ;; esac

echo "== C. payload validation =="
OUT=$(cgi '{"to":["telegram:chat:1"]}' '{}')
case "$OUT" in *missing\ text*) ok "missing text rejected" ;; *) bad "missing text" "$(printf '%s' "$OUT" | tail -1)" ;; esac
OUT=$(cgi '{"to":[],"text":"t"}' '{}')
case "$OUT" in *'"ok":true'*) ok "empty to is a no-op" ;; *) bad "empty to" "$(printf '%s' "$OUT" | tail -1)" ;; esac
OUT=$(cgi '{"to":["bogus:xx:1"],"text":"t"}' '{}')
case "$OUT" in *'"failed":1'*) ok "unknown target counted" ;; *) bad "unknown target" "$(printf '%s' "$OUT" | tail -1)" ;; esac
OUT=$(cgi 'not-json' '{}')
case "$OUT" in *'"ok":false'*) ok "malformed body rejected" ;; *) bad "malformed body" "$(printf '%s' "$OUT" | tail -1)" ;; esac

echo "== D. auth =="
OUT=$(printf '%s' '{"to":[],"text":"t"}' | env REQUEST_METHOD=POST PATH_INFO=/notify \
	REQUEST_URI=/cgi-bin/router.sh/notify QUERY_STRING='token=wrong' \
	CONTENT_LENGTH=20 AYU_ENV=dev NOTIFY_WEBHOOK_TOKEN=notifysecret \
	sh "$T/cgi-bin/router.sh")
case "$OUT" in *Forbidden*) ok "wrong token → 403" ;; *) bad "wrong token" "$OUT" ;; esac

echo "== E. button relay =="
cat >"$WORK/relay.sh" <<EOF
_HB="$T"
. "$T/lib/core.sh"
. "$T/lib/log.sh"
. "$T/lib/http.sh"
. "$T/adapter/notify/relay.sh"
notify_relay_button "\$@"
echo "rc=\$?"
EOF
KEY=$(grep -l "hook/result" "$T"/var/state/notify-cb/* 2>/dev/null | head -1 | xargs -r basename)
[ -n "$KEY" ] && ok "callback key stored ($KEY)" || bad "callback key stored" ""

: >"$WORK/relay-http.log"
R=$(RELAY qqbot interaction O1 "interaction:INTERACTION_CREATE button=retry data=action=retry&run=123&_k=$KEY msg=M1" '{"scene":"group","group_openid":"G1","group_member_openid":"U1"}')
case "$R" in *rc=0*) ok "qqbot interaction relayed" ;; *) bad "qqbot relayed" "$R" ;; esac
grep -q 'ci.example.com/hook/result' "$WORK/relay-http.log" && ok "POSTed to callback url" || bad "callback url" "$(head -3 "$WORK/relay-http.log")"
grep -q 'action=retry&run=123' "$WORK/relay-http.log" && ok "payload keeps original data" || bad "payload data" "$(grep BODY "$WORK/relay-http.log")"
grep -q '_k=' "$WORK/relay-http.log" && bad "relay key leaked" "$(grep BODY "$WORK/relay-http.log")" || ok "relay key stripped"
grep -q '"event":"button"' "$WORK/relay-http.log" && ok "payload has event=button" || bad "event field" "$(grep BODY "$WORK/relay-http.log")"
grep -q '"platform":"qqbot"' "$WORK/relay-http.log" && ok "payload has platform" || bad "platform field" ""

: >"$WORK/relay-http.log"
R=$(RELAY telegram callback C1 "btn1|action=go&_k=$KEY" '{"id":"CB1","from":{"id":7},"message":{"chat_id":100,"message_id":5}}')
case "$R" in *rc=0*) ok "telegram callback relayed" ;; *) bad "telegram relayed" "$R" ;; esac
grep -q 'answerCallbackQuery' "$WORK/relay-http.log" && ok "spinner answered" || bad "answerCallbackQuery" "$(head -5 "$WORK/relay-http.log")"

: >"$WORK/relay-http.log"
R=$(RELAY discord component "" "btn1|action=go&_k=$KEY" '{"channel_id":"200","id":"INT1"}')
case "$R" in *rc=0*) ok "discord component relayed" ;; *) bad "discord relayed" "$R" ;; esac

echo "== F. non-button traffic falls through (rc=2) =="
R=$(RELAY qqbot interaction U1 "interaction:INTERACTION_CREATE button=plain data=nokey" '{}')
case "$R" in *rc=2*) ok "keyless button → rc=2" ;; *) bad "keyless button" "$R" ;; esac
R=$(RELAY qqbot group_message U1 "普通聊天消息" '{}')
case "$R" in *rc=2*) ok "plain message → rc=2" ;; *) bad "plain message" "$R" ;; esac
R=$(RELAY telegram message C1 "普通聊天消息" '{}')
case "$R" in *rc=2*) ok "telegram message → rc=2" ;; *) bad "telegram message" "$R" ;; esac

echo "== G. dispatch chain keeps sync alive =="
cat >"$WORK/disp.sh" <<EOF
_HB="$T"
. "$T/lib/core.sh"
. "$T/lib/log.sh"
. "$T/lib/dispatch.sh"
_RULES="$WORK/rules"
dispatch "\$1" "\$2" "\$3" "\$4" "\$5"
echo done
EOF
cat >"$T/plugin/test_sink.sh" <<'EOF'
sink() { echo "SINK:$4" >> "${SINK_LOG:-/dev/null}"; return 0; }
EOF
printf 'qqbot:*|notify/relay.sh|notify_relay_button\n*|../plugin/test_sink.sh|sink\n' >"$WORK/rules"
: >"$WORK/sink.log"
SINK_LOG="$WORK/sink.log" sh "$WORK/disp.sh" qqbot group_message U1 "普通聊天消息" '{}' >/dev/null
grep -q 'SINK:普通聊天消息' "$WORK/sink.log" && ok "sync still gets the message" || bad "sync got message" "$(cat "$WORK/sink.log")"
rm -f "$T/plugin/test_sink.sh"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
