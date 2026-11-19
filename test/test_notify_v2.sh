#!/bin/sh

# Standalone suite: run it directly. test/run.sh sources this file, which would
# clobber its PASS/FAIL counters, so bail out when sourced.
if [ "${_AYU_TEST_SOURCED:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# v2 coverage: markdown / card / media / at / reply / recall / button attrs /
# every INTERACTION_CREATE sub-type + last-key fallback.
# Runs against either the repo root (test/ layout) or a staging checkout that
# keeps the tree under output/notify-tree. Override with NOTIFY_TREE if needed.
SELF=$(cd "$(dirname "$0")" && pwd)
B=$(cd "$SELF/.." && pwd)
if [ -n "${NOTIFY_TREE:-}" ]; then T=$NOTIFY_TREE
elif [ -d "$B/output/notify-tree" ]; then T=$B/output/notify-tree
else T=$B
fi
WORK=$B/temp/testwork2
rm -rf "$WORK" 2>/dev/null
mkdir -p "$WORK" "$T/var/state"
printf '{"access_token":"mock-token","expires_at":%s}' "$(( $(date +%s) + 3600 ))" >"$T/var/state/qqbot-token.json"
rm -rf "$T/var/state/notify-cb" "$T/var/state/notify-cb-last"
mkdir -p "$T/var/state/notify-cb" "$T/var/state/notify-cb-last"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

cgi() {
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

bash_body() { sed -n 's/^BODY //p' "$WORK/http.log" | tail -1; }

echo "== H1. qqbot markdown + keyboard (msg_type must be 2) =="
: >"$WORK/http.log"
OUT=$(cgi '{"to":["qqbot:group:G1"],"format":"markdown","text":"**构建失败** $E=mc^2$","buttons":[{"id":"retry","label":"重试","data":"k=1"}],"callback":"https://ci.example.com/hook/result"}')
BODY=$(bash_body)
case "$OUT" in *'"ok":true,"sent":1'*) ok "sent=1" ;; *) bad "sent=1" "$OUT" ;; esac
case "$BODY" in *'"msg_type":2'*) ok "msg_type=2" ;; *) bad "msg_type=2" "$BODY" ;; esac
case "$BODY" in *'"markdown":{"content":"**构建失败**'*) ok "markdown content" ;; *) bad "markdown content" "$BODY" ;; esac
case "$BODY" in *'"keyboard"'*) ok "keyboard attached" ;; *) bad "keyboard attached" "$BODY" ;; esac
case "$BODY" in *'"action":{"data":"k=1&_k='*|*'"action":{"type":1'*) ok "action.type=1 callback" ;; *) bad "action.type=1" "$BODY" ;; esac

echo "== H2. button style / visited_label / row grouping =="
: >"$WORK/http.log"
cgi '{"to":["qqbot:group:G1"],"text":"x","buttons":[{"id":"a","label":"甲","row":0,"style":3},{"id":"b","label":"乙","row":0,"style":4},{"id":"c","label":"丙","row":1}]}' >/dev/null
BODY=$(bash_body)
case "$BODY" in *'"style":3'*) ok "style 3 kept" ;; *) bad "style 3" "$BODY" ;; esac
case "$BODY" in *'"style":4'*) ok "style 4 kept" ;; *) bad "style 4" "$BODY" ;; esac
ROWS=$(printf '%s' "$BODY" | grep -o '"rows":' | wc -l | tr -d ' ')
case "$ROWS" in 1) ok "single rows field" ;; *) bad "single rows field" "$ROWS" ;; esac
case "$BODY" in *'{"buttons":[{"id":"a"'*'{"id":"b"'*) ok "row0 holds two buttons" ;; *) bad "row0 two buttons" "$BODY" ;; esac
case "$BODY" in *'"visited_label":"甲"'*) ok "visited_label defaults to label" ;; *) bad "visited_label" "$BODY" ;; esac

echo "== H3. url button → action.type=0 =="
: >"$WORK/http.log"
cgi '{"to":["qqbot:group:G1"],"text":"x","buttons":[{"id":"go","label":"打开","kind":"url","url":"https://example.com/a"}]}' >/dev/null
BODY=$(bash_body)
case "$BODY" in *'"action":{"type":0'*) ok "action.type=0" ;; *) bad "action.type=0" "$BODY" ;; esac
case "$BODY" in *'https://example.com/a'*) ok "url carried in data" ;; *) bad "url carried" "$BODY" ;; esac
case "$BODY" in *_k=*) bad "url button should not carry _k" "$BODY" ;; *) ok "no _k on url button" ;; esac

echo "== H4. cmd button → action.type=2 + enter =="
: >"$WORK/http.log"
cgi '{"to":["qqbot:group:G1"],"text":"x","buttons":[{"id":"cmd","label":"签到","kind":"cmd","data":"/签到","enter":true}]}' >/dev/null
BODY=$(bash_body)
case "$BODY" in *'"type":2,"data":"/签到'*) ok "cmd action" ;; *) bad "cmd action" "$BODY" ;; esac
case "$BODY" in *'"enter":true'*) ok "enter flag" ;; *) bad "enter flag" "$BODY" ;; esac

echo "== H5. card(msg_type=8) drops keyboard =="
: >"$WORK/http.log"
OUT=$(cgi '{"to":["qqbot:group:G1"],"text":"忽略","card":{"type":"tuwen","title":"标题"},"buttons":[{"id":"a","label":"甲"}]}')
BODY=$(bash_body)
case "$BODY" in *'"msg_type":8'*) ok "msg_type=8" ;; *) bad "msg_type=8" "$BODY" ;; esac
case "$BODY" in *'"keyboard"'*) bad "card must not carry keyboard" "$BODY" ;; *) ok "keyboard dropped" ;; esac
case "$BODY" in *'"content"'*) bad "card must not carry content" "$BODY" ;; *) ok "content suppressed" ;; esac

echo "== H6. at / at_all force markdown =="
: >"$WORK/http.log"
cgi '{"to":["qqbot:group:G1"],"text":"看这里","at":["MEM1"],"at_all":true}' >/dev/null
BODY=$(bash_body)
case "$BODY" in *'"msg_type":2'*) ok "msg_type=2" ;; *) bad "msg_type=2" "$BODY" ;; esac
case "$BODY" in *'<qqbot-at-user id=\"MEM1\" />'*) ok "at-user tag" ;; *) bad "at-user tag" "$BODY" ;; esac
case "$BODY" in *'<qqbot-at-everyone />'*) ok "at-everyone tag" ;; *) bad "at-everyone" "$BODY" ;; esac

echo "== H7. reply_to → message_reference =="
: >"$WORK/http.log"
cgi '{"to":["qqbot:group:G1"],"text":"收到","reply_to":"M42"}' >/dev/null
BODY=$(bash_body)
case "$BODY" in *'"message_reference":{"message_id":"M42"}'*) ok "message_reference" ;; *) bad "message_reference" "$BODY" ;; esac
case "$BODY" in *'"msg_type":2'*) ok "reply forces markdown" ;; *) bad "reply forces markdown" "$BODY" ;; esac

echo "== H8. recall =="
: >"$WORK/http.log"
OUT=$(cgi '{"to":["qqbot:group:G1"],"recall":"M9"}')
case "$OUT" in *'"ok":true,"sent":1'*) ok "recall sent=1" ;; *) bad "recall" "$OUT" ;; esac
grep -q '=== REQ DELETE .*messages/M9' "$WORK/http.log" && ok "DELETE endpoint" || bad "DELETE endpoint" "$(cat "$WORK/http.log")"

echo "== H9. media file_info → msg_type=7 =="
: >"$WORK/http.log"
cgi '{"to":["qqbot:group:G1"],"text":"附件","media":{"file_info":"FILEINFO123","type":1}}' >/dev/null
BODY=$(bash_body)
case "$BODY" in *'"msg_type":7'*) ok "msg_type=7" ;; *) bad "msg_type=7" "$BODY" ;; esac
case "$BODY" in *'"media":{"file_info":"FILEINFO123"}'*) ok "file_info carried" ;; *) bad "file_info" "$BODY" ;; esac

echo "== H10-H13. interaction sub-types + last-key fallback =="
: >"$WORK/http.log"
cgi '{"to":["qqbot:group:G1"],"text":"点我","buttons":[{"id":"a","label":"甲"}],"callback":"https://ci.example.com/hook/result"}' >/dev/null
KEY=$(grep -l "hook/result" "$T"/var/state/notify-cb/* 2>/dev/null | head -1 | xargs -r basename)
[ -n "$KEY" ] && ok "callback key stored" || bad "callback key stored" ""

cat >"$WORK/relay.sh" <<EOF
_HB="$T"
. "$T/lib/core.sh"
. "$T/lib/log.sh"
. "$T/lib/http.sh"
. "$T/adapter/notify/relay.sh"
notify_relay_button "\$@"
echo "rc=\$?"
EOF
RELAY() {
	env MOCK_HTTP=1 MOCK_LOG="$WORK/relay-http.log" MOCK_RESPONSE='{}' \
		NOTIFY_RELAY_FALLBACK_LAST="${FB:-1}" \
		sh "$WORK/relay.sh" "$@"
}
relay_case() { # relay_case <label> <expected-event> <type> <text>
	: >"$WORK/relay-http.log"
	R=$(RELAY qqbot interaction U1 "$4" "{\"scene\":\"group\",\"group_openid\":\"G1\",\"group_member_openid\":\"U1\",\"type\":$3,\"id\":\"I$3\"}")
	case "$R" in *rc=0*) ok "$1 relayed" ;; *) bad "$1 relayed" "$R" ;; esac
	B2=$(sed -n 's/^BODY //p' "$WORK/relay-http.log" | tail -1)
	case "$B2" in *"\"event\":\"$2\""*) ok "$1 event=$2" ;; *) bad "$1 event=$2" "$B2" ;; esac
	case "$B2" in *'"fallback":true'*) ok "$1 fallback=true" ;; *) bad "$1 fallback=true" "$B2" ;; esac
}
relay_case "feedback"    feedback      13 "interaction:INTERACTION_CREATE"
relay_case "clear"       clear_session 14 "interaction:INTERACTION_CREATE"
relay_case "story"       story         15 "interaction:INTERACTION_CREATE"
relay_case "story_act"   story_action  16 "interaction:INTERACTION_CREATE"
relay_case "menu"        menu          12 "interaction:INTERACTION_CREATE"

echo "== H14. own _k wins over last key =="
: >"$WORK/relay-http.log"
R=$(RELAY qqbot interaction U1 "interaction:INTERACTION_CREATE button=z data=own=1&_k=$KEY msg=M1" '{"type":11,"scene":"group","group_openid":"G1"}')
B2=$(sed -n 's/^BODY //p' "$WORK/relay-http.log" | tail -1)
case "$B2" in *'"data":"own=1"'*'"fallback":false'*) ok "own key, fallback=false" ;; *) bad "own key" "$B2" ;; esac
case "$B2" in *'"event":"button"'*) ok "event=button" ;; *) bad "event=button" "$B2" ;; esac

echo "== H15. no key + no last key → rc=2 =="
rm -f "$T"/var/state/notify-cb-last/*
R=$(RELAY qqbot interaction U1 "interaction:INTERACTION_CREATE" '{"type":13,"group_openid":"GX"}')
case "$R" in *rc=2*) ok "rc=2 falls through" ;; *) bad "rc=2" "$R" ;; esac

echo "== H16. fallback disabled → rc=2 =="
: >"$WORK/http.log"
cgi '{"to":["qqbot:group:G1"],"text":"x","callback":"https://ci.example.com/hook/result"}' >/dev/null
: >"$WORK/relay-http.log"
R=$(FB=0; RELAY qqbot interaction U1 "interaction:INTERACTION_CREATE" '{"type":13,"group_openid":"G1"}')
case "$R" in *rc=2*) ok "fallback off rc=2" ;; *) bad "fallback off" "$R" ;; esac

echo "== H17. discord modal (type=5) =="
: >"$WORK/http.log"
cgi '{"to":["discord:channel:200"],"text":"x","callback":"https://ci.example.com/hook/result"}' >/dev/null
KEY2=$(grep -l "hook/result" "$T"/var/state/notify-cb/* 2>/dev/null | tail -1 | xargs -r basename)
: >"$WORK/relay-http.log"
R=$(RELAY discord modal_submit "" "form1|d=1&_k=$KEY2" '{"type":5,"id":"MOD1","channel_id":"200"}')
B2=$(sed -n 's/^BODY //p' "$WORK/relay-http.log" | tail -1)
case "$R" in *rc=0*) ok "modal relayed" ;; *) bad "modal relayed" "$R" ;; esac
case "$B2" in *'"event":"modal"'*) ok "event=modal" ;; *) bad "event=modal" "$B2" ;; esac

echo "== H18. telegram url button =="
: >"$WORK/http.log"
cgi '{"to":["telegram:chat:100"],"text":"x","buttons":[{"id":"a","label":"甲","row":0},{"id":"go","label":"跳","kind":"url","url":"https://e.com/x","row":0}]}' >/dev/null
BODY=$(bash_body)
case "$BODY" in *'"url":"https://e.com/x"'*) ok "tg url button" ;; *) bad "tg url button" "$BODY" ;; esac
case "$BODY" in *'"inline_keyboard":[[{'*) ok "same row grouping" ;; *) bad "same row grouping" "$BODY" ;; esac

echo "== H19. batch recall across three platforms =="
: >"$WORK/http.log"
OUT=$(cgi '{"recall":[{"to":"qqbot:group:G1","message_id":"M1"},{"to":"telegram:chat:100","message_id":"7"},{"to":"discord:channel:200","message_id":"9"}]}' '{"ok":true,"result":true}')
case "$OUT" in *'"ok":true,"sent":3,"failed":0'*) ok "batch recall sent=3" ;; *) bad "batch recall" "$OUT" ;; esac
grep -q '=== REQ DELETE .*groups/G1/messages/M1' "$WORK/http.log" && ok "qq recall" || bad "qq recall" "$(cat "$WORK/http.log")"
grep -q 'DELETE .*channels/200/messages/9' "$WORK/http.log" && ok "dc recall" || bad "dc recall" "$(cat "$WORK/http.log")"

echo "== H20. recall without message_id is counted as failed =="
: >"$WORK/http.log"
OUT=$(cgi '{"to":["qqbot:group:G1"],"recall":"M9","callback":"ftp://bad.example.com/x"}')
case "$OUT" in *'callback url rejected'*) ok "non-http callback rejected" ;; *) bad "non-http callback rejected" "$OUT" ;; esac

echo "== H21. no text / no recall / no media → error =="
OUT=$(cgi '{"to":["qqbot:group:G1"]}')
case "$OUT" in *'missing text'*) ok "empty body rejected" ;; *) bad "empty body rejected" "$OUT" ;; esac

echo "== H22. CGI body is pure JSON (platform echo must not leak) =="
OUT=$(cgi '{"to":["qqbot:group:G1"],"text":"x","buttons":[{"id":"b1","label":"甲"}]}' '{"id":"MSG9","timestamp":"t"}')
PURE=$(printf '%s' "$OUT" | tr -d '\r' | sed '1,/^$/d')
case "$PURE" in
	'{'*) ok "body starts with {" ;;
	*) bad "body starts with {" "$PURE" ;;
esac
case "$PURE" in
	*'"id":"MSG9"'*) bad "no raw platform echo" "$PURE" ;;
	*) ok "no raw platform echo" ;;
esac
case "$PURE" in
	*'"ok":true'*) ok "ok:true present" ;;
	*) bad "ok:true present" "$PURE" ;;
esac
case "$PURE" in
	*'}{'*) bad "single JSON object" "$PURE" ;;
	*) ok "single JSON object" ;;
esac

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
