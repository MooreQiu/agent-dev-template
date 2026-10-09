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
tracked="$(git -C "$d/src" ls-files scripts/ | grep -c 'agent-')"
case "$tracked" in
  0) exit 90 ;;
  1) exit 91 ;;
esac
git -C "$d/src" commit -qm "baseline" || exit 50
git -C "$d/src" remote add origin "$d/origin/origin.git" || exit 50
git -C "$d/src" push -q origin HEAD:refs/heads/main || exit 50
git clone -q "$d/origin/origin.git" "$d/runner" || exit 50
[ -f "$d/runner/scripts/agent-task.sh" ] || exit 93
[ -f "$d/runner/scripts/agent-claim.sh" ] || exit 94
git -C "$d/runner" config user.name runner
git -C "$d/runner" config user.email runner@example.com

( cd "$d/runner" && bash "$d/runner/scripts/agent-task.sh" prepare 50 ) \
  > "$WORK/prep/prepare.out" 2>&1
rc=$?
echo "DIAG prepare rc=$rc" >&2
sed -n '1,10p' "$WORK/prep/prepare.out" >&2
[ "$rc" -eq 0 ] || {
  grep -Fq 'cannot fetch' "$WORK/prep/prepare.out" && exit 60
  grep -Fq 'cannot create worktree' "$WORK/prep/prepare.out" && exit 61
  grep -Fq 'cannot attach worktree' "$WORK/prep/prepare.out" && exit 62
  grep -Fq 'not inside a git repository' "$WORK/prep/prepare.out" && exit 63
  grep -Fq 'ERROR' "$WORK/prep/prepare.out" && exit 64
  grep -Fq 'unbound variable' "$WORK/prep/prepare.out" && exit 70
  grep -Fq 'command not found' "$WORK/prep/prepare.out" && exit 71
  grep -Fq 'No such file or directory' "$WORK/prep/prepare.out" && {
    grep -Eq '^cd: ' "$WORK/prep/prepare.out" && exit 80
    grep -Eq '^bash: ' "$WORK/prep/prepare.out" && {
      grep -Eq '^bash: .*agent-task' "$WORK/prep/prepare.out" && exit 85
      grep -Eq '^bash: .*agent-claim' "$WORK/prep/prepare.out" && exit 86
      exit 81
    }
    grep -Eq '^(git: |fatal: )' "$WORK/prep/prepare.out" && exit 82
    grep -Fq 'shell-init' "$WORK/prep/prepare.out" && exit 83
    grep -Eq '^(mv: |cp: |mkdir: )' "$WORK/prep/prepare.out" && exit 84
    exit 72
  }
  grep -Fq 'Usage' "$WORK/prep/prepare.out" && exit 73
  grep -Fq 'not found' "$WORK/prep/prepare.out" && exit 74
  grep -Fq 'fatal' "$WORK/prep/prepare.out" && exit 75
  exit 65
}
grep -Fq 'ERROR' "$WORK/prep/prepare.out" && exit 52
[ -d "$d/runner/.agent-work/issue-50" ] || exit 53
cd "$REPO_ROOT"
rm -rf "$WORK"
echo "DIAG-FULL-REPLAY-GREEN" >&2
exit 0
