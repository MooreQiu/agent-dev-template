#!/bin/sh
# TEMPORARY diagnostic for CI-only suite failure. test-agent-task.sh fails
# on ubuntu-latest but passes locally; this encodes the 1-based index of
# the first failing check in the exit code so the gate console line
# "gate: FAIL test exited N" pinpoints it. Removed once understood.
bash tests/test-agent-claims.sh >/dev/null 2>&1 || { echo DIAG-CLAIMS >&2; exit 250; }

out="$(bash tests/test-agent-task.sh 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "DIAG-TASK-GREEN" >&2
  exit 0
fi
n="$(printf '%s\n' "$out" | sed -n '1,/^FAIL/p' | grep -c '^ok - ')"
printf '%s\n' "$out" | sed -n '1,/^FAIL/p' | tail -3 >&2
echo "DIAG first failing check index: $((n + 1))" >&2
exit "$((n + 1))"
