#!/bin/sh
# TEMPORARY diagnostic v4: full replay of the exact make_fixture + mock gh
# + prepare sequence from tests/test-agent-task.sh check 2. Exit codes:
#   0 green; 50 make_fixture failed; 51 prepare rc nonzero;
#   52 prepare printed an ERROR; 53 worktree dir missing.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

WORK="$(mktemp -d "${TMPDIR:-/tmp}/adt-task.XXXXXX")"

MOCK_BIN="$WORK/mock-bin"
GH_LOG="$WORK/gh.log"
GH_STATE="$WORK/gh-state"
mkdir -p "$MOCK_BIN" "$GH_STATE/issue" "$GH_STATE/pr"
export GH_LOG GH_STATE
printf '1\n' > "$GH_STATE/next-pr"

cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
cmd="${1:-} ${2:-}"
case "$cmd" in
  "issue view")
    cat "$GH_STATE/issue/$3.json"
    exit 0
    ;;
  "pr view")
    if [ -f "$GH_STATE/pr/$3.json" ]; then
      cat "$GH_STATE/pr/$3.json"
      exit 0
    fi
    echo "no pull request found for $3" >&2
    exit 1
    ;;
  "pr create"|"pr edit"|"issue edit"|"issue comment")
    exit 0
    ;;
esac
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"
export PATH="$MOCK_BIN:$PATH"
export GITHUB_REPOSITORY=acme/fixture

printf '{"number":50,"title":"fixture issue 50","state":"OPEN"}\n' > "$GH_STATE/issue/50.json"

d="$WORK/prep"
mkdir -p "$d/origin" "$d/src/scripts" "$d/src/tests" "$d/src/.agent"
git init -q --bare "$d/origin/origin.git"
cp "$REPO_ROOT/scripts/agent-claim.sh" "$REPO_ROOT/scripts/agent-task.sh" "$d/src/scripts/" || exit 50
cat > "$d/src/tests/run-all.sh" <<'RUN'
#!/bin/sh
set -u
cd "$(dirname "$0")/.."
status=0
for t in tests/test*.sh; do
  [ -e "$t" ] || continue
  bash "$t" || status=1
done
exit "$status"
RUN
printf '#!/bin/sh\necho ok\n' > "$d/src/tests/test-ok.sh"
cat > "$d/src/.agent/project.json" <<'CFG'
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
git -C "$d/src" init -q || exit 50
git -C "$d/src" add -A || exit 50
git -C "$d/src" commit -qm "baseline" || exit 50
git -C "$d/src" remote add origin "$d/origin/origin.git" || exit 50
git -C "$d/src" push -q origin HEAD:refs/heads/main || exit 50
git clone -q "$d/origin/origin.git" "$d/runner" || exit 50
git -C "$d/runner" config user.name runner
git -C "$d/runner" config user.email runner@example.com

( cd "$d/runner" && bash "$d/runner/scripts/agent-task.sh" prepare 50 ) \
  > "$WORK/prep/prepare.out" 2>&1
rc=$?
echo "DIAG prepare rc=$rc" >&2
sed -n '1,10p' "$WORK/prep/prepare.out" >&2
[ "$rc" -eq 0 ] || exit 51
grep -Fq 'ERROR' "$WORK/prep/prepare.out" && exit 52
[ -d "$d/runner/.agent-work/issue-50" ] || exit 53
cd "$REPO_ROOT"
rm -rf "$WORK"
echo "DIAG-FULL-REPLAY-GREEN" >&2
exit 0
