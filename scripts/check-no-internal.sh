#!/bin/bash
# Spec §5.4: fails when a tracked text file contains a denylisted internal word. The denylist
# (scripts/internal-denylist.sha256) holds SHA-256 hashes of lowercased whole words, never the words, so this public
# repository never spells them; output names file:line only. Read-only.
# Usage: scripts/check-no-internal.sh [--root <repo>]   exit 1 on a hit, 0 clean, 64 usage
#        scripts/check-no-internal.sh --hash <word>     print the denylist line for <word>
set -uo pipefail
usage() { echo "usage: $0 [--root <repo>] | --hash <word>" >&2; exit 64; }
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] && [ -d "$2" ] || usage; ROOT="$(cd "$2" && pwd -P)"; shift ;;
    --hash) [ $# -ge 2 ] || usage; printf %s "$2" | tr '[:upper:]' '[:lower:]' | shasum -a 256 | cut -d' ' -f1; exit 0 ;;
    *) usage ;;
  esac
  shift
done
DENY="$ROOT/scripts/internal-denylist.sha256"
[ -f "$DENY" ] || { echo "check-no-internal: no $DENY" >&2; exit 64; }
python3 -I - "$ROOT" "$DENY" <<'PY'
import hashlib, re, subprocess, sys
root, deny = sys.argv[1], sys.argv[2]
hashes = {l.split()[0] for l in open(deny, encoding="utf-8") if l.strip() and not l.startswith("#")}
files = subprocess.run(["git", "-C", root, "grep", "-Il", ""], capture_output=True, text=True, check=True).stdout.splitlines()
word, seen, hits = re.compile(r"[a-z0-9]+"), {}, 0
for f in files:
    if f == "scripts/internal-denylist.sha256":
        continue
    try:
        lines = open(f"{root}/{f}", encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for n, line in enumerate(lines, 1):
        for w in set(word.findall(line.lower())):
            bad = seen.get(w)
            if bad is None:
                bad = seen[w] = hashlib.sha256(w.encode()).hexdigest() in hashes
            if bad:
                print(f"INTERNAL: {f}:{n}: denylisted word"); hits += 1
sys.exit(1 if hits else 0)
PY
