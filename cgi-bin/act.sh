#!/bin/sh
# act.sh — the only writable endpoint the XML panel can reach
#
#   GET /cgi-bin/act.sh?n=<nonce>&op=pause    stop the panel's auto-refresh
#   GET /cgi-bin/act.sh?n=<nonce>&op=resume   resume it
#
# How a click gets here: XML has no form controls, so the pad is a CSS rule
#
#     pad[op="pause"]:active { background-image: url(".../act.sh?n=..&op=pause") }
#
# A mouse-down loads that image, the request lands here, and the response is a
# 1x1 GIF so the browser is satisfied. There is no response body to read: the
# click is a write, the panel shows the result on its next refresh.
#
# Deliberate limits:
#   * op is a two-entry allowlist. Nothing here restarts, deletes or
#     reconfigures anything — a fire-and-forget GET must never be able to.
#   * the nonce comes from the panel's own stylesheet, which is served only to
#     an authenticated caller, and it expires (see _NONCE_TTL in web.sh). A
#     stranger cannot guess it, and a leaked URL dies within minutes.
#   * every accepted command is logged, so a stuck pause/resume is auditable.
#
# This endpoint is intentionally not authenticated by cookie: a CSS background
# request carries whatever cookie the browser has, and requiring one would make
# the mechanism fail silently in privacy modes. The nonce is the credential.

_HB="$(cd "$(dirname "$0")/.." && pwd)"
. "$_HB/lib/core.sh"
. "$_HB/etc/config.sh"
. "$_HB/lib/log.sh"
. "$_HB/lib/auth.sh"

_NONCE_TTL=180
_QS="${QUERY_STRING:-}"

# Answer with a GIF no matter what happens: a broken image icon in the pad would
# look like a panel bug rather than a rejected command.
_gif() {
	printf 'Content-Type: image/gif\r\n'
	printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
	printf 'Content-Length: 43\r\n\r\n'
	printf 'GIF89a\001\000\001\000\200\000\000\000\000\000\377\377\377!\371\004\001\000\000\000\000,\000\000\000\000\001\000\001\000\000\002\002D\001\000;'
}

_n="$(auth_query_param "$_QS" n | tr -dc '0-9a-f')"
_op="$(auth_query_param "$_QS" op)"

case "$_op" in
	pause|resume) ;;
	*) _gif; exit 0 ;;
esac

# --- nonce check ---------------------------------------------------------

_nf="$_STATE_DIR/web-nonce"
_ok=1
if [ -z "$_n" ] || [ ! -f "$_nf" ]; then
	_ok=0
else
	_now="$(date +%s)"
	_ok=0
	while read -r _sn _sts; do
		[ "$_sn" = "$_n" ] || continue
		case "$_sts" in ''|*[!0-9]*) continue ;; esac
		[ "$_sts" -ge "$((_now - _NONCE_TTL))" ] && _ok=1
		break
	done < "$_nf"
fi

if [ "$_ok" != "1" ]; then
	log_warn "web: act '$_op' rejected (unknown or expired nonce)"
	_gif
	exit 0
fi

# --- command -------------------------------------------------------------

if auth_misconfigured; then
	log_err "web: act '$_op' refused — AYU_ENV=${AYU_ENV:-?} without WEBHOOK_SECRET"
	_gif
	exit 0
fi

case "$_op" in
	pause)
		: > "$_STATE_DIR/web-paused"
		log_info "web: auto-refresh paused by panel click"
		;;
	resume)
		rm -f "$_STATE_DIR/web-paused"
		log_info "web: auto-refresh resumed by panel click"
		;;
esac

_gif
exit 0
