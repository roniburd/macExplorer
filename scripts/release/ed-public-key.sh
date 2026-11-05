#!/bin/bash
# scripts/release/ed-public-key.sh: prints the base64 Sparkle EdDSA public key that belongs to a private key.
# Usage: printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | scripts/release/ed-public-key.sh
# The private key is what `generate_keys -x` exports (and what sign_update --ed-key-file reads): base64 of a 32-byte
# ed25519 seed, or of the older 96-byte form (64-byte private key followed by the 32-byte public key).
# A 32-byte seed needs an OpenSSL with Ed25519 (OpenSSL 3; macOS's LibreSSL lacks it): $OPENSSL, else Homebrew's
# openssl@3, else `openssl` on PATH. The key only ever lives in a mktemp directory that is deleted on exit.
# Exit status: 0 printed, 1 bad key or no usable OpenSSL, 64 bad arguments.
set -euo pipefail
[ "$#" -eq 0 ] || { echo "usage: printf '%s\\n' \"\$KEY\" | $0" >&2; exit 64; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/macx-edkey-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

secret="$(tr -d '[:space:]')"
printf '%s' "$secret" | base64 -D > "$tmp/raw" 2>/dev/null || { echo "error: private key is not base64" >&2; exit 1; }
size="$(wc -c < "$tmp/raw" | tr -d ' ')"

case "$size" in
96)
    tail -c 32 "$tmp/raw" | base64
    ;;
32)
    ossl="${OPENSSL:-}"
    if [ -z "$ossl" ] && command -v brew >/dev/null 2>&1; then
        prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
        [ -x "$prefix/bin/openssl" ] && ossl="$prefix/bin/openssl"
    fi
    ossl="${ossl:-openssl}"
    # PKCS#8 DER wrapper for a raw Ed25519 private key (RFC 8410), then the seed.
    { printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20'; cat "$tmp/raw"; } > "$tmp/key.der"
    if ! "$ossl" pkey -inform DER -in "$tmp/key.der" -pubout -outform DER -out "$tmp/pub.der" 2>/dev/null; then
        echo "error: $ossl can't read Ed25519 keys (install openssl@3 or set OPENSSL)" >&2; exit 1
    fi
    tail -c 32 "$tmp/pub.der" | base64
    ;;
*)
    echo "error: decoded private key is $size bytes; want 32 (seed) or 96 (older format)" >&2; exit 1
    ;;
esac
