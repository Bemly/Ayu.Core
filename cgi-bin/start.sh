#!/bin/sh
# start.sh — launch Ayu.Core httpd server

_HB="$(cd "$(dirname "$0")/.." && pwd)"
cd "$_HB" || exit 1

. ./lib/core.sh
. ./etc/config.sh
. ./lib/log.sh

mkdir -p var/log var/state /tmp/img

# Fix permissions (tar/rsync may land code as another uid; busybox httpd
# answers 404 for CGI scripts it cannot attribute to the server user).
if [ "$(id -u)" = "0" ]; then
	chown root:root "$_HB"/*.md "$_HB"/index.xml "$_HB"/Dockerfile "$_HB"/LICENSE 2>/dev/null
	chown -R root:root "$_HB"/cgi-bin "$_HB"/adapter "$_HB"/lib "$_HB"/plugin \
		"$_HB"/etc "$_HB"/hush-json "$_HB"/hush-ed25519 "$_HB"/test 2>/dev/null
fi
# Group-readable, never world-readable: logs and state carry chat metadata.
find "$_HB" -name "*.sh" -exec chmod u+x,g+rx,o-rwx {} + 2>/dev/null
chmod 2750 var var/log var/state 2>/dev/null
chmod 640 var/log/*.log 2>/dev/null
find "$_HB/var/state" -type f -exec chmod 640 {} + 2>/dev/null

log_info "Ayu.Core starting on ${BOT_HOST}:${BOT_PORT}"
log_info "QQ API: ${QQ_API_BASE}"
log_info "log dir: ${_LOG_DIR}"

# --- boot-time maintenance: rotate/trim logs, drop stale temp uploads ---
# Never touches var/state (message maps), /tmp/img or the forwarded-media cache.
if [ -f "$_HB/plugin/maint/clean.sh" ]; then
	( . "$_HB/plugin/maint/clean.sh"; maint_run boot ) || log_warn "maint: boot run failed"
else
	log_warn "maint: plugin/maint/clean.sh missing"
fi

# --- launch crond (scheduled tasks via etc/crontab) ---
_cron_tab="$_HB/etc/crontab"
_cron_file="/var/spool/cron/crontabs/root"
if [ -f "$_cron_tab" ]; then
	mkdir -p "$(dirname "$_cron_file")"
	> "$_cron_file"
	while IFS='|' read -r _time _sc _fn _; do
		case "$_time" in \#*|"") continue ;; esac
		_sc_path="$_HB/adapter/$_sc"
			_fn="${_fn%%#*}"  # Strip inline comment
		printf '%s sh -c "timeout 300 sh -c \"_HB=%s . %s && %s\"" >> %s/var/log/cron.log 2>&1\n' \
			"$_time" "$_HB" "$_sc_path" "$_fn" "$_HB" >> "$_cron_file"
	done < "$_cron_tab"
	crond -l 5 &
	log_info "crond: started with $(wc -l < "$_cron_file") job(s)"
else
	log_info "crond: no $_cron_tab, skipped"
fi

# No -v/-vv: busybox httpd's access log echoes the full request line, which
# contains the webhook ?token=... value. Request paths are logged by router.sh
# (without the query string) instead.
exec httpd -f -h "$_HB" -p "$BOT_PORT" -c etc/httpd.conf
