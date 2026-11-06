# auth.sh — webhook shared-secret authentication
# Source after core.sh (uses url_decode from lib/url.sh)

# auth_query_param <query_string> <name> → decoded value on stdout
# Tolerates the name appearing anywhere in the query string and never returns
# the raw query string when the parameter is absent.
auth_query_param() {
	_aq_qs="$1" _aq_name="$2"
	_aq_v=""
	case "&$_aq_qs&" in
		*"&$_aq_name="*)
			_aq_v="${_aq_qs#*"$_aq_name="}"
			_aq_v="${_aq_v%%&*}"
			;;
	esac
	printf '%s' "$_aq_v"
}

# auth_check <query_string> [secret] → 0 allowed, 1 rejected
# No secret configured → open (single-tenant loopback deployment).
# Secret configured → constant-ish compare of the ?token= parameter.
auth_check() {
	_auth_qs="$1" _auth_secret="${2:-${WEBHOOK_SECRET:-}}"
	[ -z "$_auth_secret" ] && return 0
	_auth_tok="$(auth_query_param "$_auth_qs" token)"
	[ -n "$_auth_tok" ] || return 1
	_auth_tok="$(url_decode "$_auth_tok")"
	[ "$_auth_tok" = "$_auth_secret" ] && return 0
	return 1
}
