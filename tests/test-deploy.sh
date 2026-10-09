#!/usr/bin/env bash
# Acceptance tests for issue #11: complete template deployment and merge config.
# Run: bash tests/test-deploy.sh
#
# Exercises deploy.sh and setup.sh against fixture repositories with a mocked
# gh CLI (no network access). Verifies:
#   - all required template artifacts are deployed and explicitly staged
#   - existing customized files are preserved and reported (no false success)
#   - the target default branch is resolved consistently (no hardcoded main)
#   - merge configuration: linear history required + squash merges everywhere
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-test-deploy.XXXXXX")"
GH_LOG="$TMP/gh.log"
PROTECT_LOG="$TMP/protection.json"
MOCK_BRANCH="trunk"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

failures=0
check() { # check <description> <command> [args...]
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    failures=$((failures + 1))
  fi
}

# --- mocked gh (records every call; never touches the network) ------------
MOCK_BIN="$TMP/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$*" in
  *nameWithOwner*) echo "acme/fixture" ;;
  *defaultBranchRef*) echo "$MOCK_BRANCH" ;;
  *"/branches/"*"/protection"*) cat >> "$PROTECT_LOG" ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/gh"

make_fixture() { # <dir>: repo on branch trunk with a bare origin remote
  rm -rf "$1" "$1.git"
  mkdir -p "$1"
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD refs/heads/trunk
  echo "# fixture" > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q -m "init"
  git init -q --bare "$1.git"
  git -C "$1" remote add origin "$1.git"
  git -C "$1" push -q origin trunk
}

run_deploy() { # <fixture-dir> <outfile>
  ( cd "$REPO_ROOT" && PATH="$MOCK_BIN:$PATH" ANTHROPIC_AUTH_TOKEN= \
      bash deploy.sh "$1" ) > "$2" 2>&1 || true
}

# --- AC1: fresh deployment copies and explicitly stages every artifact ----
echo "== fresh deployment =="
FIX="$TMP/fresh"
make_fixture "$FIX"
: > "$GH_LOG"
run_deploy "$FIX" "$TMP/out-fresh.txt"

REQUIRED='AGENTS.md CLAUDE.md INSTALL.md docs/HARNESSES.md scripts/agent.sh
.specify/memory/constitution.md .claude/commands/claim.md
.claude/skills/speckit-plan/SKILL.md .github/ISSUE_TEMPLATE/config.yml
.github/PULL_REQUEST_TEMPLATE.md .github/workflows/claude.yml
.github/workflows/agent-sweep.yml .github/workflows/pr-review.yml
.github/workflows/project-sync.yml setup.sh'

for f in $REQUIRED; do
  check "$f deployed to fixture" test -f "$FIX/$f"
  check "$f staged in deploy commit" git -C "$FIX" ls-files --error-unmatch "$f"
done

# --- AC3: default branch resolved, not assumed to be main -----------------
check "deploy branch created" \
  sh -c 'test "$(git -C "$1" rev-parse --abbrev-ref HEAD)" = chore/agent-dev-template' sh "$FIX"
check "deploy branch based on target default branch (trunk)" \
  sh -c 'test "$(git -C "$1" rev-parse chore/agent-dev-template^)" = "$(git -C "$1" rev-parse origin/trunk)"' sh "$FIX"
check "deploy queried the target default branch" \
  sh -c 'grep -q defaultBranchRef "$1"' sh "$GH_LOG"
check "complete deployment reported" \
  sh -c 'grep -q "全部必要组件已部署" "$1"' sh "$TMP/out-fresh.txt"

# --- AC2: customized files preserved and incomplete deployment reported ---
echo "== customized file preservation =="
FIX="$TMP/custom"
make_fixture "$FIX"
printf 'my customized agents file\n' > "$FIX/AGENTS.md"
: > "$GH_LOG"
run_deploy "$FIX" "$TMP/out-custom.txt"

check "customized AGENTS.md preserved byte-for-byte" \
  sh -c 'test "$(cat "$1")" = "my customized agents file"' sh "$FIX/AGENTS.md"
check "skipped component reported" \
  sh -c 'grep -q "已存在，跳过: AGENTS.md" "$1"' sh "$TMP/out-custom.txt"
check "incomplete deployment reported" \
  sh -c 'grep -q "部署不完整" "$1"' sh "$TMP/out-custom.txt"
check "no false complete-deployment claim" \
  sh -c '! grep -q "全部必要组件已部署" "$1"' sh "$TMP/out-custom.txt"
check "customized file not pulled into deploy commit" \
  sh -c '! git -C "$1" ls-files --error-unmatch AGENTS.md' sh "$FIX"
check "remaining artifacts still deployed" test -f "$FIX/CLAUDE.md"

# --- AC3 + AC4: setup.sh branch resolution and merge configuration --------
echo "== setup.sh branch and merge configuration =="
: > "$GH_LOG"
: > "$PROTECT_LOG"
( cd "$REPO_ROOT" && PATH="$MOCK_BIN:$PATH" ANTHROPIC_AUTH_TOKEN= \
    bash setup.sh --repo=acme/fixture --skip-secrets ) > "$TMP/out-setup.txt" 2>&1 || true

check "branch protection targets default branch (trunk)" \
  sh -c 'grep -q "branches/trunk/protection" "$1"' sh "$GH_LOG"
check "branch protection does not hardcode main" \
  sh -c '! grep -q "branches/main/protection" "$1"' sh "$GH_LOG"
check "linear history required in protection" \
  sh -c 'grep -q "\"required_linear_history\": true" "$1"' sh "$PROTECT_LOG"
check "squash merge allowed in repo settings" \
  sh -c 'grep -q -- "--allow-squash-merge" "$1"' sh "$GH_LOG"
check "auto-merge enabled" \
  sh -c 'grep -q -- "--enable-auto-merge" "$1"' sh "$GH_LOG"

# --- AC4 + AC3: workflow merge method and branch references ---------------
echo "== workflow merge and branch configuration =="
WF="$REPO_ROOT/.github/workflows"

check "pr-review merges via squash" sh -c 'grep -q -- " --squash" "$1"' sh "$WF/pr-review.yml"
check "pr-review avoids merge commits" sh -c '! grep -q " --merge " "$1"' sh "$WF/pr-review.yml"
check "workflows do not hardcode --base main" sh -c '! grep -rq -- "--base main" "$1"' sh "$WF"
check "claude.yml resolves default branch dynamically" \
  sh -c 'grep -q "github.event.repository.default_branch" "$1"' sh "$WF/claude.yml"
check "agent-sweep.yml resolves default branch dynamically" \
  sh -c 'grep -q "github.event.repository.default_branch" "$1"' sh "$WF/agent-sweep.yml"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
