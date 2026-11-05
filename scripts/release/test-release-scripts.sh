#!/bin/bash
# Tests for appcast.py and render-cask.sh. Writes only inside its own mktemp directory.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/macx-release-test-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

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
python3 -I "$here/appcast.py" --appcast "$ac" --version x 2>/dev/null && fail "missing args accepted"

cask="$("$here/render-cask.sh" --token macexplorer@beta --version 0.2.0-beta.1 --sha256 abc123 --url https://example.invalid/a.zip)"
grep -q 'cask "macexplorer@beta" do' <<<"$cask" || fail "cask token"
grep -q 'version "0.2.0-beta.1"' <<<"$cask" || fail "cask version"
grep -q 'sha256 "abc123"' <<<"$cask" || fail "cask sha"
grep -q 'auto_updates true' <<<"$cask" || fail "auto_updates"
grep -q 'conflicts_with cask: "macexplorer"' <<<"$cask" || fail "conflicts"
grep -q 'app "MacExplorer.app"' <<<"$cask" || fail "app stanza"
"$here/render-cask.sh" --token other --version 1 --sha256 a --url u >/dev/null 2>&1 && fail "bad token accepted"
echo "release scripts: OK"
