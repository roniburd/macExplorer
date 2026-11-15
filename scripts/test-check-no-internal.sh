#!/bin/bash
# Self-test for scripts/check-no-internal.sh, in ONE fresh ${TMPDIR}/macx-tests-<UUID> directory (removed on exit).
# Exit 0 when every case behaves, 1 otherwise.
# No -e: the script checks every exit status itself and reports each failure.
set -uo pipefail
CHECK="$(cd "$(dirname "$0")" && pwd -P)/check-no-internal.sh"
TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
SB="$TMPBASE/macx-tests-$(uuidgen)"
mkdir "$SB" || exit 2
trap 'case "$SB" in "$TMPBASE"/macx-tests-*) rm -rf "$SB" ;; esac' EXIT
fail=0
repo() {
  mkdir -p "$SB/$1/scripts" && git -C "$SB/$1" init -q && printf '%s\n' "$2" > "$SB/$1/a.txt"
  "$CHECK" --hash zorblax > "$SB/$1/scripts/internal-denylist.sha256"
  printf '%s sub\n' "$("$CHECK" --hash glimmox)" >> "$SB/$1/scripts/internal-denylist.sha256"
  git -C "$SB/$1" add -A
}
expect() { # expect <case> <exit code>
  "$CHECK" --root "$SB/$1" >"$SB/$1.out" 2>&1; local got=$?
  if [ "$got" -ne "$2" ]; then echo "FAIL $1: exit $got, want $2"; cat "$SB/$1.out"; fail=1; else echo "ok $1"; fi
}
repo clean "nothing to see here"; expect clean 0
repo hit "see the Zorblax.example host"; expect hit 1
grep -q "a.txt:1:" "$SB/hit.out" || { echo "FAIL hit: no file:line"; fail=1; }
grep -qi zorblax "$SB/hit.out" && { echo "FAIL hit: output spells the word"; fail=1; }
repo part "zorblaxes are fine"; expect part 0
repo camel "let c = ZorblaxClient()"; expect camel 1
repo digit "id zorblax1.id"; expect digit 1
repo acronym "the ZORBLAXServer type"; expect acronym 1
repo fused "x.zorblaxhost.com"; expect fused 0
repo subroot "x.glimmoxhost.com and MyGlimmoxes"; expect subroot 1
repo quoted "clean"; mkdir -p "$SB/quoted/d"; printf 'zorblax\n' > "$SB/quoted/d/caf\303\251 x.txt"; git -C "$SB/quoted" add -A
expect quoted 1
grep -q "a.txt" "$SB/quoted.out" && { echo "FAIL quoted: hit in the wrong file"; fail=1; }
repo untracked "clean"; printf 'zorblax\n' > "$SB/untracked/new.txt"; expect untracked 0
[ "$("$CHECK" --hash Zorblax)" = "$(printf %s zorblax | shasum -a 256 | cut -d' ' -f1)" ] || { echo "FAIL hash"; fail=1; }
exit "$fail"
