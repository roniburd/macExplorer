#!/bin/bash
# Creates the §9 golden fixture tree in a fresh ${TMPDIR}/macx-fixtures-<UUID> directory and prints its path.
#   scripts/make-fixtures.sh                 golden tree only
#   scripts/make-fixtures.sh --flat 100000   golden tree + flat-100000/ with that many empty files
#   scripts/make-fixtures.sh --remove <dir>  deletes a directory this script created (and nothing else)
# Safety: never writes outside the directory it creates; --remove refuses any other path.
set -euo pipefail

TMP="${TMPDIR:-/tmp}"
TMP="$(cd "$TMP" && pwd -P)"
PREFIX="$TMP/macx-fixtures-"

refuse() { echo "make-fixtures: refusing: $1" >&2; exit 2; }

if [[ "${1:-}" == "--remove" ]]; then
    target="$(cd "${2:?usage: --remove <dir>}" && pwd -P)"
    [[ "$target" == "$PREFIX"* && "$target" != */*/../* ]] || refuse "$target is not a macx-fixtures directory in $TMP"
    chflags -R nouchg,nohidden "$target" 2>/dev/null || true
    chmod -R u+rwx "$target" 2>/dev/null || true
    rm -rf -- "$target"
    exit 0
fi

FLAT=0
if [[ "${1:-}" == "--flat" ]]; then FLAT="${2:?usage: --flat <count>}"; fi
[[ "$FLAT" =~ ^[0-9]+$ ]] || refuse "--flat needs a number"

ROOT="$PREFIX$(uuidgen)"
mkdir "$ROOT"
G="$ROOT/golden"
inside() { [[ "$1" == "$ROOT/"* ]] || refuse "$1 is outside $ROOT"; }
mkdir "$G"; cd "$G"; inside "$PWD/x"

printf 'hello\n' > plain.txt
: > empty.bin
dd if=/dev/zero of=sparse.bin bs=1 count=0 seek=$((8 * 1024 * 1024 - 1)) 2>/dev/null; printf 'x' >> sparse.bin
printf 'x' > "$(printf 'R\xc3\xa9sum\xc3\xa9.txt')"          # NFC
printf 'x' > "$(printf 'Cafe\xcc\x81.txt')"                 # NFD
printf 'x' > "$(printf 'emoji \xf0\x9f\x98\x80\xf0\x9f\x8e\x89.txt')"
printf 'x' > "$(printf 'n%.0s' $(seq 1 251)).txt"           # 255 bytes
printf 'x' > "$(for _ in $(seq 1 85); do printf '\xe6\x97\xa5'; done)"   # 85 × 3 bytes
printf 'x' > .dot-hidden
printf 'x' > flag-hidden.txt; chflags hidden flag-hidden.txt
ln -s plain.txt link-to-plain; ln -s folder link-to-folder; ln -s does-not-exist broken-link
mkdir -p Tool.app/Contents/MacOS; printf '<plist/>' > Tool.app/Contents/Info.plist; printf 'x' > Tool.app/Contents/MacOS/Tool
mkdir Note.rtfd; printf '{\\rtf1}' > Note.rtfd/TXT.rtf
mkdir -p folder/sub; printf 'x' > folder/a.txt; printf 'x' > folder/b.txt
mkdir v1.2; printf 'x' > v1.2/inside.txt
printf 'x' > locked.txt; chflags uchg locked.txt
printf 'x' > with-xattrs.txt; xattr -w com.macexplorer.test value with-xattrs.txt
printf 'linked' > hardlink-a.txt; ln hardlink-a.txt hardlink-b.txt
mkdir no-access-dir; printf 'x' > no-access-dir/secret.txt; chmod 000 no-access-dir
printf 'x' > no-access.txt; chmod 000 no-access.txt
printf '#!/bin/sh\n' > run.sh; chmod 755 run.sh
printf 'x' > read-only.txt; chmod 444 read-only.txt
printf 'x' > dated.txt; touch -t 200202020000 dated.txt
# Not created by the shell version (need Foundation): alias-to-plain, ext-hidden.txt. FixtureTree.golden makes them.

if (( FLAT > 0 )); then
    F="$ROOT/flat-$FLAT"; mkdir "$F"; cd "$F"; inside "$PWD/x"
    for ((i = 1; i <= FLAT; i += 1000)); do
        end=$(( i + 999 < FLAT ? i + 999 : FLAT ))
        touch $(seq -f 'file-%06g.txt' "$i" "$end")
    done
fi
echo "$ROOT"
