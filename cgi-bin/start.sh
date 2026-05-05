#!/bin/sh
# start.sh — launch Ayu.Core httpd server

_HB="$(cd "$(dirname "$0")/.." && pwd)"
cd "$_HB" || exit 1

. ./lib/core.sh
. ./etc/config.sh
. ./lib/log.sh

mkdir -p var/log var/state

# Fix permissions (tar loses execute bits, httpd CGI may run as non-root)
find "$_HB" -name "*.sh" -exec chmod +x {} + 2>/dev/null
chmod 777 var/log var/state 2>/dev/null
chmod 666 var/log/*.log 2>/dev/null

log_info "Ayu.Core starting on ${BOT_HOST}:${BOT_PORT}"
log_info "QQ API: ${QQ_API_BASE}"
log_info "log dir: ${_LOG_DIR}"

# --- launch crond (scheduled tasks via etc/crontab) ---
_cron_tab="$_HB/etc/crontab"
_cron_file="/var/spool/cron/crontabs/root"
if [ -f "$_cron_tab" ]; then
	mkdir -p "$(dirname "$_cron_file")"
	> "$_cron_file"
	while IFS='|' read -r _time _sc _fn _; do
		case "$_time" in \#*|"") continue ;; esac
		# Resolve script path relative to adapter/ (same convention as etc/rules)
		_sc_path="$_HB/adapter/$_sc"
		printf '%s sh -c ". %s && %s"\n' \
			"$_time" "$_sc_path" "$_fn" >> "$_cron_file"
	done < "$_cron_tab"
	crond -l 5 &
	log_info "crond: started with $(wc -l < "$_cron_file") job(s)"
else
	log_info "crond: no $_cron_tab, skipped"
fi

httpd -f -h "$_HB" -p "$BOT_PORT" -c etc/httpd.conf -vv
