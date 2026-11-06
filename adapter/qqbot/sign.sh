# adapter/qqbot/sign.sh — Ed25519 helpers for QQ Bot callbacks
#
# QQ derives the signing key from the Bot Secret:
#   seed = secret repeated until length >= 32, then truncated to 32 bytes
# (confirmed against the official callback-validation demo vector).
#
# The runtime image (busybox:musl) ships no openssl/python, so signing is done
# by the static helper built from tools/ed25519/ into var/tools/ayu-ed25519.
# Without that binary op=13 address validation cannot succeed; inbound event
# signature checks then fall back to the ?token= shared secret only.

# qqbot_sign_bin → path of a usable helper, or 1
qqbot_sign_bin() {
	case "${QQBOT_ED25519_BIN:-}" in
		/*) [ -x "$QQBOT_ED25519_BIN" ] && { printf '%s' "$QQBOT_ED25519_BIN"; return 0; } ;;
	esac
	for _qsb in "$_HB/var/tools/ayu-ed25519" "$(command -v ayu-ed25519 2>/dev/null)"; do
		if [ -n "$_qsb" ] && [ -x "$_qsb" ]; then
			printf '%s' "$_qsb"
			return 0
		fi
	done
	return 1
}

# qqbot_sign_bin_usable → 0 when the helper can actually run in this image
# 127 = wrong libc ("not found"), 126 = not executable for this uid (the file
# is 0750 and owned by the deploy user, container uid 0 is "other").
qqbot_sign_bin_usable() {
	_qsu_path="$(qqbot_sign_bin)" || return 1
	_qsu_err="$("$_qsu_path" 2>&1 >/dev/null)"
	_qsu_rc=$?
	case "$_qsu_rc" in 126|127) return 1 ;; esac
	case "$_qsu_err" in *"not found"*|*"Permission denied"*) return 1 ;; esac
	return 0
}

# qqbot_ed_sign <msg_file> → lowercase hex signature
# The secret travels via the environment, never as argv (no `ps` leak).
qqbot_ed_sign() {
	qqbot_configured || { _ERROR="qqbot.sign: app id/secret not configured"; return 1; }
	_qsbin="$(qqbot_sign_bin)" || { _ERROR="qqbot.sign: ayu-ed25519 helper not found"; return 1; }
	_qssig="$(AYU_ED25519_SECRET="$QQBOT_APP_SECRET" "$_qsbin" sign - "$1" 2>/dev/null)"
	[ -n "$_qssig" ] || { _ERROR="qqbot.sign: signing failed"; return 1; }
	printf '%s' "$_qssig"
}

# qqbot_ed_verify <msg_file> <sig_hex> → 0 valid / 1 invalid
qqbot_ed_verify() {
	qqbot_configured || return 1
	_qvbin="$(qqbot_sign_bin)" || return 1
	[ -n "$2" ] || return 1
	AYU_ED25519_SECRET="$QQBOT_APP_SECRET" "$_qvbin" verify - "$1" "$2" 2>/dev/null
}

# qqbot_signature_enabled → 0 when inbound signatures must be checked
#   auto (default): check only when both secret and a runnable helper exist
#   1 / on        : always require the check (a missing helper then rejects
#                   every callback, i.e. fails closed, never open)
#   0 / off       : never check (rely on ?token= WEBHOOK_SECRET)
qqbot_signature_enabled() {
	case "$QQBOT_VERIFY_SIG" in
		0|off|no|false) return 1 ;;
		1|on|yes|true) return 0 ;;
	esac
	qqbot_configured || return 1
	qqbot_sign_bin_usable
}
