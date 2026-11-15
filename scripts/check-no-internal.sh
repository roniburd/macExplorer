#!/bin/bash
# Spec §5.4: fails when a tracked text file contains a denylisted internal word. The denylist
# (scripts/internal-denylist.sha256) holds SHA-256 hashes of lowercased words, never the words (a
# trailing "sub" also matches the word inside a longer run), so this public
# repository never spells them; output names file:line only. Read-only.
# Usage: scripts/check-no-internal.sh [--root <repo>]   exit 1 on a hit or an unreadable file, 0 clean, 64 usage
#        scripts/check-no-internal.sh --hash <word>     print the denylist line for <word>
# No -e: the script checks every exit status itself and reports each failure.
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
# A denylist line is "<hash>" (whole word or camelCase/digit piece) or "<hash> sub" (also matched inside longer runs,
# e.g. a root fused into a host name).
whole, sub = set(), set()
for l in open(deny, encoding="utf-8"):
    parts = l.split()
    if parts and not parts[0].startswith("#"):
        (sub if parts[1:2] == ["sub"] else whole).add(parts[0])
whole |= sub
# -z: raw NUL-separated paths, so names git would quote (non-ASCII, special characters) are still scanned.
out = subprocess.run(["git", "-C", root, "grep", "-z", "-Il", ""], capture_output=True, check=True).stdout
files = [f.decode("utf-8", "surrogateescape") for f in out.split(b"\0") if f]
runs = re.compile(r"[A-Za-z0-9]+")
pieces = re.compile(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|[0-9]+")
H = lambda w: hashlib.sha256(w.encode()).hexdigest()
seen, hits, errors = {}, 0, 0
def bad(run):
    r = seen.get(run)
    if r is None:
        toks = {run.lower()} | {p.lower() for p in pieces.findall(run)}
        r = any(H(t) in whole for t in toks)
        if not r and sub:
            low = run.lower()
            r = any(H(low[i:j]) in sub for i in range(len(low)) for j in range(i + 3, min(len(low), i + 32) + 1))
        seen[run] = r
    return r
for f in files:
    if f == "scripts/internal-denylist.sha256":
        continue
    try:
        lines = open(f"{root}/{f}".encode("utf-8", "surrogateescape"), encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        print(f"check-no-internal: cannot read {f}: {e.strerror}", file=sys.stderr); errors += 1
        continue
    for n, line in enumerate(lines, 1):
        if any(bad(w) for w in set(runs.findall(line))):
            print(f"INTERNAL: {f}:{n}: denylisted word"); hits += 1
sys.exit(1 if hits or errors else 0)
PY
