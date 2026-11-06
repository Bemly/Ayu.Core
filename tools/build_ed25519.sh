#!/bin/sh
# build_ed25519.sh — build the static ayu-ed25519 helper into var/tools/
#
# The runtime image (busybox:musl) has no openssl/python, so the Ed25519
# helper must be a static binary. Build it once on the host, then ship
# var/tools/ayu-ed25519 with the deployment (var/ is gitignored).
#
# Requires: gcc + libssl-dev (Debian: apt install build-essential libssl-dev)
# Usage: sh tools/build_ed25519.sh [output-path]

set -e
_HERE="$(cd "$(dirname "$0")" && pwd)"
_ROOT="$(cd "$_HERE/.." && pwd)"
_OUT="${1:-$_ROOT/var/tools/ayu-ed25519}"

mkdir -p "$(dirname "$_OUT")"

gcc -O2 -static -o "$_OUT" "$_HERE/ed25519/ayu_ed25519.c" \
	-lcrypto -lz -ldl -pthread 2>&1 | grep -v 'warning: Using .getaddrinfo' || true

chmod 750 "$_OUT"
printf 'built: %s (%s bytes)\n' "$_OUT" "$(wc -c <"$_OUT" | tr -d ' ')"

# self-check against the official QQ Bot callback-validation demo
# (secret DG5g3B4j9X2KOErG, event_ts 1725442341, plain_token Arq0D5A61EgUu4OxUvOp)
_MSG="$(mktemp)"
printf '%s' '1725442341Arq0D5A61EgUu4OxUvOp' >"$_MSG"
_sig="$("$_OUT" sign DG5g3B4j9X2KOErG "$_MSG")"
rm -f "$_MSG"
printf 'demo signature: %s\n' "$_sig"
if [ "$_sig" = "87befc99c42c651b3aac0278e71ada338433ae26fcb24307bdc5ad38c1adc2d01bcfcadc0842edac85e85205028a1132afe09280305f13aa6909ffc2d652c706" ]; then
	printf 'self-check: OK\n'
else
	printf 'self-check: MISMATCH\n' >&2
	exit 1
fi
