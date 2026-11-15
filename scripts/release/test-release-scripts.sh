#!/bin/bash
# Tests for appcast.py and render-cask.sh. Writes only inside its own mktemp directory.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/macx-release-test-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$here/../lib/openssl.sh"

ac="$tmp/appcast.xml"
add() { python3 -I "$here/appcast.py" --appcast "$ac" --url "https://example.invalid/$1.zip" --length 123 \
          --ed-signature "sig$2" --min-os 26.0 --notes-url "https://example.invalid/notes/$1" --version "$1" --build "$2" "${@:3}"; }

add 0.2.0-beta.1 10 --channel beta
add 0.2.0 11
add 0.2.0 11                                  # same build again: replaced, not duplicated
python3 -I - "$ac" <<'PY' || fail "appcast content"
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = ET.parse(sys.argv[1]).getroot().find("channel").findall("item")
assert len(items) == 2, len(items)
newest = items[0]
assert newest.find("sparkle:version", ns).text == "11"
assert newest.find("sparkle:shortVersionString", ns).text == "0.2.0"
assert newest.find("sparkle:channel", ns) is None
beta = items[1]
assert beta.find("sparkle:channel", ns).text == "beta"
enc = beta.find("enclosure")
assert enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature") == "sig10"
assert enc.get("length") == "123" and enc.get("type") == "application/octet-stream"
assert beta.find("sparkle:minimumSystemVersion", ns).text == "26.0"
PY
# Bad arguments must exit 64 (EX_USAGE); the Release workflow relies on it.
expect_64() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 64 ] || fail "$1 bad args: exit $rc, want 64"; }
expect_64 python3 -I "$here/appcast.py" --appcast "$ac" --version x

cask="$("$here/render-cask.sh" --token macexplorer@beta --version 0.2.0-beta.1 --sha256 abc123 --url https://example.invalid/a.zip)"
grep -q 'cask "macexplorer@beta" do' <<<"$cask" || fail "cask token"
grep -q 'version "0.2.0-beta.1"' <<<"$cask" || fail "cask version"
grep -q 'sha256 "abc123"' <<<"$cask" || fail "cask sha"
grep -q 'auto_updates true' <<<"$cask" || fail "auto_updates"
grep -q 'conflicts_with cask: "macexplorer"' <<<"$cask" || fail "conflicts"
grep -q 'app "MacExplorer.app"' <<<"$cask" || fail "app stanza"
grep -qF '"~/Library/Saved Application State/com.macexplorer.app.savedState",' <<<"$cask" || fail "zap saved state"
grep -qF '"~/Library/Caches/com.macexplorer.app",' <<<"$cask" || fail "zap Sparkle cache"
grep -qF '"~/Library/HTTPStorages/com.macexplorer.app",' <<<"$cask" || fail "zap HTTP storage"
expect_64 "$here/render-cask.sh" --token other --version 1 --sha256 a --url u
expect_64 "$here/render-cask.sh" --token macexplorer --version 1 --sha256 a
expect_64 "$here/render-cask.sh" --bogus

# ed-public-key.sh: the Release workflow refuses to publish when the secret's public key isn't SUPublicEDKey.
edkey="$here/ed-public-key.sh"
expect_64 "$edkey" extra-arg
# Older 96-byte form: the public key is the last 32 bytes.
head -c 64 /dev/urandom > "$tmp/old"; head -c 32 /dev/urandom > "$tmp/oldpub"
want="$(base64 < "$tmp/oldpub")"
got="$(cat "$tmp/old" "$tmp/oldpub" | base64 | "$edkey")" || fail "ed-public-key 96-byte form"
[ "$got" = "$want" ] || fail "ed-public-key 96-byte form: $got != $want"
# Bad keys fail.
printf 'not base64!!\n' | "$edkey" >/dev/null 2>&1 && fail "ed-public-key accepted garbage"
head -c 31 /dev/urandom | base64 | "$edkey" >/dev/null 2>&1 && fail "ed-public-key accepted 31 bytes"
# A 32-byte seed (what generate_keys -x exports today) needs OpenSSL 3.
ossl="$(macx_openssl)"
if "$ossl" genpkey -algorithm ed25519 -outform DER -out "$tmp/k.der" 2>/dev/null; then
    tail -c 32 "$tmp/k.der" | base64 > "$tmp/seed"
    want="$("$ossl" pkey -inform DER -in "$tmp/k.der" -pubout -outform DER | tail -c 32 | base64)"
    got="$(OPENSSL="$ossl" "$edkey" < "$tmp/seed")" || fail "ed-public-key seed form"
    [ "$got" = "$want" ] || fail "ed-public-key seed form: $got != $want"
    # Cross-check with Sparkle itself: a signature made by sign_update verifies under the derived public key.
    sign_update="$here/../../.build/artifacts/sparkle/Sparkle/bin/sign_update"
    if [ -x "$sign_update" ]; then
        printf 'payload\n' > "$tmp/payload"
        sig="$("$sign_update" --ed-key-file - -p "$tmp/payload" < "$tmp/seed")" || fail "sign_update"
        printf '%s' "$sig" | base64 -D > "$tmp/sig"
        { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$got" | base64 -D; } > "$tmp/pub.der"
        "$ossl" pkeyutl -verify -pubin -inkey "$tmp/pub.der" -keyform DER -rawin -in "$tmp/payload" -sigfile "$tmp/sig" \
            >/dev/null || fail "sign_update signature doesn't verify under the derived public key"
    else
        echo "note: Sparkle sign_update not found (swift package resolve); skipped the Sparkle cross-check" >&2
    fi
else
    echo "note: no OpenSSL with Ed25519 ($ossl); skipped the seed-form test" >&2
fi
# wait-for-ci.sh against a fake gh (prints the runs in $FAKE_RUNS, one per line, like the real --jq output).
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/bin/bash
[ -s "$FAKE_RUNS" ] && cat "$FAKE_RUNS"; exit 0
SH
chmod +x "$tmp/bin/gh"
wait_ci() {   # wait_ci <want exit> <run lines...>
    local want="$1" rc=0; shift
    printf '%s\n' "$@" > "$tmp/runs"
    PATH="$tmp/bin:$PATH" FAKE_RUNS="$tmp/runs" GITHUB_REPOSITORY=o/r TIMEOUT_SECONDS=0 POLL_SECONDS=0 APPEAR_SECONDS=0 \
        "$here/wait-for-ci.sh" abc123 > "$tmp/wait.out" 2>&1 || rc=$?
    [ "$rc" -eq "$want" ] || { cat "$tmp/wait.out" >&2; fail "wait-for-ci ($*): exit $rc, want $want"; }
}
wait_ci 0 "completed success push main https://x/1"
wait_ci 1 "completed failure push main https://x/1"
# The push-to-main run decides over a pull-request run of the same commit, either way.
wait_ci 1 "completed success pull_request feature https://x/2" "completed failure push main https://x/1"
wait_ci 0 "completed failure pull_request feature https://x/2" "completed success push main https://x/1"
# Still running on main: not decided by the pull request's success (times out here, TIMEOUT_SECONDS=0).
wait_ci 1 "completed success pull_request feature https://x/2" "in_progress - push main https://x/1"
grep -q 'https://x/1' "$tmp/wait.out" || fail "wait-for-ci should name the pending main run"
# No main run, or only cancelled ones: any other run decides.
wait_ci 0 "completed success pull_request feature https://x/2"
wait_ci 0 "completed cancelled push main https://x/1" "completed success workflow_dispatch v1.0.0 https://x/3"
wait_ci 3 "completed cancelled push main https://x/1"
wait_ci 3
# git-credential-env.sh: answers get from GIT_TOKEN only; never store/erase, nothing without a token.
helper="$here/git-credential-env.sh"
got="$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TOKEN=tok "$helper" get)"
[ "$got" = "$(printf 'username=x-access-token\npassword=tok')" ] || fail "git-credential-env get: $got"
[ -z "$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TOKEN= "$helper" get)" ] || fail "git-credential-env without a token"
[ -z "$(printf 'protocol=https\nhost=github.com\npassword=x\n\n' | GIT_TOKEN=tok "$helper" store)" ] || fail "git-credential-env store"
echo "release scripts: OK"
