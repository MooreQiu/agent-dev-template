#!/bin/sh
# TEMPORARY diagnostic for CI-only suite failure: exits with the 1-based
# alphabetical index of the first failing test file so the gate console
# line "gate: FAIL test exited N" identifies the culprit. Removed once
# the failure is understood.
i=0
for t in tests/test*.sh; do
  i=$((i + 1))
  if ! bash "$t" >/dev/null 2>&1; then
    echo "DIAG-FAILED:$t (index $i)" >&2
    exit "$i"
  fi
done
echo "DIAG-ALL-GREEN" >&2
exit 0
