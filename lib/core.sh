# Ayu.Core core — error handling + hush-json bootstrap
# Source this first: . ./lib/core.sh

# Default file policy: owner write, group read/traverse, no other access.
# Deployments can still grant a specific shared group at the filesystem level.
umask 027

# ---- hush-json ----
# Use _HB (bot root) if set, otherwise fall back to $(pwd)
: "${_HB:=$(pwd)}"
_JSON_HOME="$_HB/hush-json"
. "$_JSON_HOME/lib/json.sh"

# ---- hush-url ----
. "$_HB/lib/url.sh"

# ---- global error state ----
# hush has no trap ERR, no FUNCNAME, no BASH_LINENO.
# Manual error chain: set _ERROR on failure, propagate up with ||
_ERROR=""
_ERRLINE=""

# die <msg> [exit_code] — print error with line number and exit
die() {
    _msg="$1" _code="${2:-1}"
    _line="${_ERRLINE:-$LINENO}"
    printf '%s ERROR (line %s): %s\n' "$(date +%T)" "$_line" "$_msg" >&2
    exit "$_code"
}
