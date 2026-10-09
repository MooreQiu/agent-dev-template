#!/bin/sh
# TEMPORARY diagnostic for CI-only failure of test-agent-task.sh check 2
# ("prepare succeeds"). Exit codes reported via "gate: FAIL test exited N":
#   0        everything green
#   20-23    fixture replay failed at that step
#   10       git fetch --prune failed
#   12       git worktree add -b failed
#   240      task test crashed without a FAIL line
#   1..99    task test: index of first failing check
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export GIT_AUTHOR_NAME=diag GIT_AUTHOR_EMAIL=diag@example.com
export GIT_COMMITTER_NAME=diag GIT_COMMITTER_EMAIL=diag@example.com
W="$(mktemp -d "${TMPDIR:-/tmp}/diag-prep.XXXXXX")"

mkdir -p "$W/origin" "$W/src/scripts" "$W/src/tests" "$W/src/.agent"
git init -q --bare "$W/origin/origin.git" || exit 20
cp scripts/agent-claim.sh scripts/agent-task.sh "$W/src/scripts/" || exit 21
printf '#!/bin/sh\necho ok\n' > "$W/src/tests/test-ok.sh"
cat > "$W/src/.agent/project.json" <<'CFG'
{
  "commands": {
    "install": "",
    "build": "",
    "test": "bash tests/run-all.sh",
    "lint": "",
    "typecheck": ""
  }
}
CFG
git -C "$W/src" init -q || exit 30
git -C "$W/src" add -A || exit 31
git -C "$W/src" commit -qm baseline || exit 32
git -C "$W/src" remote add origin "$W/origin/origin.git" || exit 33
git -C "$W/src" push -q origin HEAD:refs/heads/main || exit 34
git clone -q "$W/origin/origin.git" "$W/runner" || exit 23
git -C "$W/runner" config user.name runner
git -C "$W/runner" config user.email runner@example.com

# Replay the exact prepare sequence from cmd_prepare.
cd "$W/runner" || exit 23
git fetch --quiet --prune origin || exit 10
git worktree list --porcelain >/dev/null 2>&1 || exit 11
git worktree add -b agent/issue-50 "$W/runner/.agent-work/issue-50" origin/main >/dev/null 2>&1 || exit 12
cd "$REPO_ROOT" || exit 23
rm -rf "$W"

# Prepare chain is green on this runner: locate the failing check.
out="$(bash tests/test-agent-task.sh 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "DIAG-ALL-GREEN" >&2
  exit 0
fi
fails="$(printf '%s\n' "$out" | grep -c '^FAIL')"
if [ "$fails" -eq 0 ]; then
  echo "DIAG-TASK-CRASHED-NO-FAIL-LINE" >&2
  printf '%s\n' "$out" | tail -5 >&2
  exit 240
fi
n="$(printf '%s\n' "$out" | sed -n '1,/^FAIL/p' | grep -c '^ok - ')"
echo "DIAG first failing check index: $((n + 1))" >&2
exit "$((n + 1))"
