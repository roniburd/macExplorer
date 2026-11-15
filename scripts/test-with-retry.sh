#!/bin/bash
# Runs `swift test --parallel` and retries each failed XCTest case once, alone, so one timing-dependent test on a
# slow shared CI runner does not fail the whole run. Used by ci.yml (Test step).
# Usage: scripts/test-with-retry.sh [extra swift test arguments...]
# - Failed cases are read from the xUnit XML (`--xunit-output`); classname is <Module>.<Class>, name is the test.
# - No retry when the run failed with 0 parsed failures (build error, crash without a report) or with more than
#   MAX_RETRIES (default 2) failures: that is real breakage.
# - Each failed case is re-run alone with `--skip-build --filter '^<Module>\.<Class>/<test>$'`; every retry must
#   pass AND appear in its own xUnit report (a filter that matches nothing does not count as a pass).
# - A case that failed then passed is reported as a `::warning title=Flaky test::` annotation (and in
#   $GITHUB_STEP_SUMMARY when set), and a `FLAKY: <n> test case(s) passed only on retry: <cases>` line is printed
#   whenever any case passed on retry, also when another failed again. Exit 0 when the first run or every retry
#   passed, 1 otherwise.
# The xUnit reports are kept in .build/test-results/ (first.xml, retry-<n>.xml) for the CI artifact
# (MACX_TEST_RESULTS overrides the folder; the self-test uses a temporary one).
set -euo pipefail
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."
. scripts/lib/retry.sh

MAX_RETRIES="${MAX_RETRIES:-2}"
OUT="${MACX_TEST_RESULTS:-.build/test-results}"

# failed_cases <xunit file>: prints "<classname>/<name>" for every testcase with a <failure> or <error> child.
failed_cases() {
  python3 -I -c '
import sys, xml.etree.ElementTree as ET
for case in ET.parse(sys.argv[1]).getroot().iter("testcase"):
    if case.find("failure") is not None or case.find("error") is not None:
        print(case.get("classname", "") + "/" + case.get("name", ""))
' "$1"
}

# passed_case <xunit file> <classname/name>: true when the report holds that case and it did not fail.
passed_case() {
  python3 -I -c '
import sys, xml.etree.ElementTree as ET
found = [c for c in ET.parse(sys.argv[1]).getroot().iter("testcase")
         if c.get("classname", "") + "/" + c.get("name", "") == sys.argv[2]]
sys.exit(0 if found and all(c.find("failure") is None and c.find("error") is None for c in found) else 1)
' "$1" "$2"
}

# case_filter <classname/name>: the --filter regular expression (over <Module>.<Class>/<test>) for exactly that case.
case_filter() { local cls="${1%%/*}" name="${1#*/}"; printf '^%s/%s$' "${cls//./\\.}" "$name"; }

# Self-check (no real tests run): scripts/test-with-retry.sh --self-test. Checks the two parsers on a hand-written
# report, the retry rule and FLAKY line of scripts/lib/retry.sh, and whole runs of this script against a fake `swift`.
if [ "${1:-}" = "--self-test" ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/macx-test-retry-XXXXXX")"
  trap 'rm -rf "$OUT"' EXIT
  cat > "$OUT/sample.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
<testsuite name="TestResults" errors="0" tests="3" failures="1" time="1.0">
<testcase classname="CoreTests.FolderModelTests" name="testRapidNavigationDropsStaleGenerations" time="0.5">
<failure message="failed"></failure>
</testcase>
<testcase classname="CoreTests.FolderModelTests" name="testOther" time="0.1">
</testcase>
<testcase classname="UITests.TypeSelectTests" name="testLargeFolderSearchRunsOffMainAndApplies" time="0.2">
<failure message="failed"></failure>
</testcase>
</testsuite>
</testsuites>
XML
  got="$(failed_cases "$OUT/sample.xml" | tr '\n' ' ')"
  want="CoreTests.FolderModelTests/testRapidNavigationDropsStaleGenerations UITests.TypeSelectTests/testLargeFolderSearchRunsOffMainAndApplies "
  [ "$got" = "$want" ] || { echo "self-test: failed_cases printed '$got'" >&2; exit 1; }
  passed_case "$OUT/sample.xml" CoreTests.FolderModelTests/testOther || { echo "self-test: testOther should pass" >&2; exit 1; }
  ! passed_case "$OUT/sample.xml" UITests.TypeSelectTests/testLargeFolderSearchRunsOffMainAndApplies \
    || { echo "self-test: a failed case counted as passed" >&2; exit 1; }
  ! passed_case "$OUT/sample.xml" CoreTests.Missing/testNothing || { echo "self-test: a missing case counted as passed" >&2; exit 1; }
  [ "$(case_filter CoreTests.FolderModelTests/testOther)" = '^CoreTests\.FolderModelTests/testOther$' ] \
    || { echo "self-test: case_filter printed '$(case_filter CoreTests.FolderModelTests/testOther)'" >&2; exit 1; }

  st_fail() { echo "self-test: $*" >&2; exit 1; }
  # The retry rule: MAX_RETRIES defaults to 2.
  ( unset MAX_RETRIES; macx_retry_allowed 2 && ! macx_retry_allowed 3 && ! macx_retry_allowed 0 ) \
    || st_fail "macx_retry_allowed should allow 1-2 failures by default"
  ( MAX_RETRIES=3; macx_retry_allowed 3 ) || st_fail "macx_retry_allowed ignores MAX_RETRIES"
  [ "$(macx_flaky_line "test case(s)" A/a B/b)" = "FLAKY: 2 test case(s) passed only on retry: A/a B/b" ] \
    || st_fail "macx_flaky_line printed '$(macx_flaky_line "test case(s)" A/a B/b)'"
  [ -z "$(macx_flaky_line "test case(s)")" ] || st_fail "macx_flaky_line printed a line without names"

  # Whole runs against a fake swift: FAKE_FIRST lists the cases failing in the first run, FAKE_STILL those that also
  # fail when retried alone; every call is appended to calls.txt.
  mkdir -p "$OUT/bin"
  cat > "$OUT/bin/swift" <<'SWIFT'
#!/bin/bash
out=""; filter=""
while [ $# -gt 0 ]; do
  case "$1" in --xunit-output) out="$2"; shift ;; --filter) filter="$2"; shift ;; esac; shift
done
echo "swift $filter" >> "$FAKE_DIR/calls.txt"
if [ -z "$filter" ]; then cases="$FAKE_FIRST"; fails="$FAKE_FIRST"
else c="${filter#^}"; c="${c%$}"; cases="${c//\\/}"; fails="$FAKE_STILL"; fi
code=0
{ echo '<testsuites><testsuite name="TestResults">'
  for c in $cases; do
    printf '<testcase classname="%s" name="%s">' "${c%%/*}" "${c#*/}"
    case " $fails " in *" $c "*) printf '<failure message="failed"></failure>'; code=1 ;; esac
    echo '</testcase>'
  done
  echo '</testsuite></testsuites>'; } > "$out"
exit "$code"
SWIFT
  chmod +x "$OUT/bin/swift"
  # run_fake <first> <still>: runs this script; sets rc, log (its output) and calls (how many swift runs).
  run_fake() {
    rm -rf "$OUT/run" "$OUT/calls.txt"; : > "$OUT/calls.txt"
    rc=0
    log="$(env -u MAX_RETRIES -u GITHUB_STEP_SUMMARY PATH="$OUT/bin:$PATH" FAKE_DIR="$OUT" FAKE_FIRST="$1" \
           FAKE_STILL="$2" MACX_TEST_RESULTS="$OUT/run" "$self" 2>&1)" || rc=$?
    calls="$(wc -l < "$OUT/calls.txt" | tr -d ' ')"
  }
  run_fake "M.A/a M.B/b M.C/c" ""
  [ "$rc" = 1 ] && [ "$calls" = 1 ] || st_fail "3 failures (over the default MAX_RETRIES 2): rc $rc, $calls swift runs: $log"
  run_fake "M.A/a M.B/b" "M.B/b"
  [ "$rc" = 1 ] && [ "$calls" = 3 ] || st_fail "one flaky and one real failure: rc $rc, $calls swift runs: $log"
  case "$log" in *"FLAKY: 1 test case(s) passed only on retry: M.A/a"*) ;; *) st_fail "a red run lacks the FLAKY line: $log" ;; esac
  case "$log" in *"M.B/b failed again on retry"*) ;; *) st_fail "a red run does not name the real failure: $log" ;; esac
  run_fake "M.A/a" ""
  [ "$rc" = 0 ] && [ "$calls" = 2 ] || st_fail "one flaky failure: rc $rc, $calls swift runs: $log"
  [ "$(printf '%s\n' "$log" | tail -1)" = "FLAKY: 1 test case(s) passed only on retry: M.A/a" ] \
    || st_fail "a green retry run does not end with the FLAKY line: $log"
  echo "test-with-retry self-test: ok"; exit 0
fi

rm -rf "$OUT" && mkdir -p "$OUT"
if swift test --parallel --xunit-output "$OUT/first.xml" "$@"; then
  # Shows the report format the retry relies on (<Module>.<Class>/<test>) in every green log.
  [ ! -s "$OUT/first.xml" ] || python3 -I -c '
import sys, xml.etree.ElementTree as ET
cases = list(ET.parse(sys.argv[1]).getroot().iter("testcase"))
print("test-with-retry: %d test cases in the xUnit report, e.g. %s" % (len(cases),
      cases[0].get("classname") + "/" + cases[0].get("name") if cases else "none"))
' "$OUT/first.xml"
  exit 0
fi

failed=()
if [ -s "$OUT/first.xml" ]; then
  while IFS= read -r c; do [ -n "$c" ] && failed+=("$c"); done < <(failed_cases "$OUT/first.xml")
fi
if [ ${#failed[@]} -eq 0 ]; then
  echo "::error title=Tests::swift test failed with no failed test case in the xUnit report (build error or crash); not retrying"
  exit 1
fi
if ! macx_retry_allowed ${#failed[@]}; then
  echo "::error title=Tests::${#failed[@]} test cases failed (more than $MAX_RETRIES); not retrying"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi

echo "test-with-retry: ${#failed[@]} failed test case(s); retrying each once, alone"
flaky=(); still=()
i=0
for c in "${failed[@]}"; do
  i=$((i + 1))
  filter="$(case_filter "$c")"
  echo "--- retry $c (filter $filter)"
  if swift test --skip-build --parallel --num-workers 1 --filter "$filter" --xunit-output "$OUT/retry-$i.xml" "$@" \
      && [ -s "$OUT/retry-$i.xml" ] && passed_case "$OUT/retry-$i.xml" "$c"; then
    flaky+=("$c")
  else
    still+=("$c")
  fi
done

if [ ${#flaky[@]} -gt 0 ]; then
  for c in "${flaky[@]}"; do echo "::warning title=Flaky test::$c failed then passed on retry"; done
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo '### Flaky tests (failed, then passed on retry)'; printf -- '- `%s`\n' "${flaky[@]}"; } >> "$GITHUB_STEP_SUMMARY"
  fi
fi
if [ ${#still[@]} -gt 0 ]; then
  for c in "${still[@]}"; do echo "::error title=Test failed::$c failed again on retry"; done
  macx_flaky_line "test case(s)" ${flaky[@]+"${flaky[@]}"}
  exit 1
fi
macx_flaky_line "test case(s)" "${flaky[@]}"
exit 0
