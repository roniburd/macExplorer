#!/bin/bash
# scripts/lib/openssl.sh: source it for macx_openssl, which prints the OpenSSL to use for Ed25519 keys: $OPENSSL, else
# Homebrew's openssl@3, else `openssl` on PATH (macOS's LibreSSL lacks Ed25519, so callers must still check it works).
# Used by scripts/release/ed-public-key.sh and scripts/release/test-release-scripts.sh.
macx_openssl() {
  local ossl="${OPENSSL:-}" prefix
  if [ -z "$ossl" ] && command -v brew >/dev/null 2>&1; then
    prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
    if [ -x "$prefix/bin/openssl" ]; then ossl="$prefix/bin/openssl"; fi
  fi
  printf '%s\n' "${ossl:-openssl}"
}
