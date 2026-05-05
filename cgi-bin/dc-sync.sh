#!/bin/sh
# dc-sync.sh — Daily Discord message sync to QQ/TG
# Called via cron: wget -q http://127.0.0.1:6160/cgi-bin/dc-sync.sh?token=xxx
# Filters messages from today and forwards per etc/sync.conf

# ---- bootstrap ----
_HB="$(dirname "$0")/.."
. "$_HB/lib/core.sh"
. "$_HB/etc/config.sh"
. "$_HB/lib/log.sh"
. "$_HB/lib/http.sh"
. "$_HB/adapter/discord/core.sh"
. "$_HB/adapter/discord/message.sh"
. "$_HB/plugin/sync/common.sh"
. "$_HB/plugin/sync/from_dc.sh"

# ---- auth check ----
if [ -n "${WEBHOOK_SECRET:-}" ]; then
	_token="$(printf '%s' "${QUERY_STRING:-}" | sed 's/.*token=//' | sed 's/&.*//')"
	_token="$(url_decode "$_token")"
	if [ "$_token" != "$WEBHOOK_SECRET" ]; then
		printf 'Content-Type: text/plain\r\n\r\n'
		printf '403 Forbidden'
		exit 0
	fi
fi

# ---- check DC_TOKEN ----
if [ -z "$DC_TOKEN" ]; then
	printf 'Content-Type: application/json\r\n\r\n'
	printf '{"error":"DC_TOKEN not configured"}'
	exit 0
fi

_conf="${_SYNC_CONF:-$_HB/etc/sync.conf}"
if [ ! -f "$_conf" ]; then
	printf 'Content-Type: application/json\r\n\r\n'
	printf '{"error":"no sync.conf"}'
	exit 0
fi

log_info "dc-sync: starting daily fetch"

# Collect unique DC source channels from sync.conf
_channels=""
while IFS='=' read -r _src _tgt; do
	case "$_src" in \#*|"") continue ;; esac
	_spf="${_src%%/*}"
	[ "$_spf" != "discord" ] && continue
	_cid="${_src#*/}"
	_channels="$_channels $_cid"
done < "$_conf"

# Deduplicate
_channels="$(printf '%s' "$_channels" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
log_info "dc-sync: channels=$_channels"

_today="$(env TZ=UTC date +%Y-%m-%d)"
_total=0 _fwd=0

for _cid in $_channels; do
	[ -z "$_cid" ] && continue
	log_info "dc-sync: fetching channel $_cid"

	# Fetch recent messages
	_resp="$(dc_message_list "$_cid" 2>/dev/null)" || {
		log_err "dc-sync: list FAIL $_cid: $_ERROR"; continue
	}
	if [ -z "$_resp" ] || [ "$_resp" = "NOTFOUND" ] || [ "$_resp" = "[]" ]; then
		log_info "dc-sync: channel $_cid empty"; continue
	fi

	# Split JSON array into individual message objects
	_msgs="$(printf '%s' "$_resp" | sed 's/^{"id":"/\n{"id":"/g' | sed 's/^\[//;s/\]$//' | grep -v '^$')"

	for _msg in $_msgs; do
		[ -z "$_msg" ] && continue
		_total=$((_total + 1))

		# Check timestamp is today
		_ts="$(json_get "$_msg" timestamp 2>/dev/null)" || _ts=""
		if [ -z "$_ts" ] || [ "$_ts" = "NOTFOUND" ]; then continue; fi
		case "$_ts" in
			"$_today"*) ;;
			*) continue ;;
		esac

		# Forward this message
		sync_dc_message "$_msg" "$_cid"
		_fwd=$((_fwd + 1))
	done
done

log_info "dc-sync: done total=$_total fwd=$_fwd"

printf 'Content-Type: application/json\r\n\r\n'
printf '{"status":"ok","total":%d,"forwarded":%d}' "$_total" "$_fwd"
exit 0
