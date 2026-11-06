# adapter/qqbot/sign.sh — Ed25519 helpers for QQ Bot callbacks
#
# QQ derives the signing key from the Bot Secret:
#   seed = secret repeated until length >= 32, then truncated to 32 bytes
# (confirmed against the official callback-validation demo vector).
#
# The runtime image (busybox:musl) ships no openssl/python, so signing and
# verification run on hush-ed25519 (submodule: pure shell + BusyBox awk).
# Without that library op=13 address validation cannot succeed; inbound event
# signature checks then fall back to the ?token= shared secret only.
#
# hush-ed25519 exits when its awk engine is missing, so it is sourced lazily
# from qqbot_ed_load() and the engine path is probed first.

# qqbot_ed_load → source hush-ed25519 once; 0 = ready
# The library exits when its awk engine cannot be found, so probe first: a
# missing submodule must degrade to "no signature check", never kill the CGI.
qqbot_ed_load() {
	[ -n "${_QQBOT_ED_LOADED:-}" ] && return 0
	if [ ! -f "$QQBOT_ED25519_HOME/lib/awk/ed25519_engine.awk" ]; then
		_ERROR="qqbot.sign: hush-ed25519 not found at $QQBOT_ED25519_HOME"
		return 1
	fi
	_ED25519_HOME="$QQBOT_ED25519_HOME"
	. "$QQBOT_ED25519_HOME/lib/ed25519.sh" || {
		_ERROR="qqbot.sign: hush-ed25519 failed to load"
		return 1
	}
	_QQBOT_ED_LOADED=1
	return 0
}

# qqbot_ed_usable → 0 when signing/verifying can run in this image
qqbot_ed_usable() {
	qqbot_ed_load >/dev/null 2>&1 || return 1
	for _qeu in awk sha512sum xxd dd; do
		command -v "$_qeu" >/dev/null 2>&1 || return 1
	done
	return 0
}

# qqbot_ed_sign <msg_file> → lowercase hex signature
# The secret stays in process memory: it is a shell argument inside this
# process only, never an argv of a child (no `ps` leak), and hush-ed25519
# feeds it to awk over a pipe.
qqbot_ed_sign() {
	qqbot_configured || { _ERROR="qqbot.sign: app id/secret not configured"; return 1; }
	qqbot_ed_load || return 1
	_qs_sig="$(ed25519_sign_secret "$QQBOT_APP_SECRET" "$1" 2>/dev/null)"
	[ -n "$_qs_sig" ] || { _ERROR="qqbot.sign: signing failed${_ED25519_ERROR:+ ($_ED25519_ERROR)}"; return 1; }
	printf '%s' "$_qs_sig"
}

# qqbot_ed_verify <msg_file> <sig_hex> → 0 valid / 1 invalid
qqbot_ed_verify() {
	qqbot_configured || return 1
	qqbot_ed_load || return 1
	[ -n "$2" ] || return 1
	ed25519_verify_secret "$QQBOT_APP_SECRET" "$1" "$2" 2>/dev/null
}

# qqbot_signature_enabled → 0 when inbound signatures must be checked
#   auto (default): check only when both secret and hush-ed25519 exist
#   1 / on        : always require the check (a missing library then rejects
#                   every callback, i.e. fails closed, never open)
#   0 / off       : never check (rely on ?token= WEBHOOK_SECRET)
qqbot_signature_enabled() {
	case "$QQBOT_VERIFY_SIG" in
		0|off|no|false) return 1 ;;
		1|on|yes|true) return 0 ;;
	esac
	qqbot_configured || return 1
	qqbot_ed_usable
}
