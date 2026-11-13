#!/usr/bin/env bash
# Browser tests in CI (#277/#279): one node process per test file, in series. A failing file is run once more;
# the first failure's output is kept as annotations (so a flaky test stays visible), and a file that fails twice
# fails the job. A skipped test is a failure (no browser = no check). Run from web/.
set -uo pipefail
files=$(ls test/*.test.ts | grep -E '(-browser|^test/shot|^test/ipad)')
echo "$files"
log="$RUNNER_TEMP/browser-logs"; mkdir -p "$log"
rc=0; flaky=""; total=0; skipped=0
ann() { grep -a -v -E '^ *(duration_ms|type:|location|stack|at )' "$1" | grep -a -E -B2 -A14 '^ *not ok|page error|bin/shot|rror' | cut -c1-240 | head -${2:-40} | while IFS= read -r l; do echo "::warning::$3 $l"; done; }
for f in $files; do
  t0=$SECONDS
  node --test --test-reporter=tap "$f" > "$log/$(basename "$f").1.tap" 2>&1; s=$?
  if [ $s -ne 0 ]; then
    echo "::warning::FIRST ATTEMPT FAILED: $f"
    ann "$log/$(basename "$f").1.tap" 40 "[$(basename "$f") try 1]"
    node --test --test-reporter=tap "$f" > "$log/$(basename "$f").2.tap" 2>&1; s=$?
    if [ $s -eq 0 ]; then flaky="$flaky $f"; else echo "::error::$f failed twice"; ann "$log/$(basename "$f").2.tap" 40 "[$(basename "$f") try 2]"; rc=1; fi
    last="$log/$(basename "$f").2.tap"
  else last="$log/$(basename "$f").1.tap"; fi
  sk=$(grep -a -E '^# skipped ' "$last" | awk '{print $3}'); skipped=$((skipped + ${sk:-0}))
  n=$(grep -a -E '^# tests ' "$last" | awk '{print $3}'); total=$((total + ${n:-0}))
  echo "$f: exit $s, $((SECONDS - t0)) s, tests ${n:-0}, skipped ${sk:-0}"
done
echo "tests $total, skipped $skipped, flaky (passed on retry):${flaky:- none}"
[ -n "$flaky" ] && echo "::warning::flaky browser test files (passed on retry):$flaky"
if [ "$skipped" -ne 0 ]; then echo "::error::browser tests were skipped"; rc=1; fi
if [ "$total" -eq 0 ]; then echo "::error::no browser tests ran"; rc=1; fi
exit $rc
