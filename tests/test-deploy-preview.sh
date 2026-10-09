#!/usr/bin/env bash
# Acceptance tests for issue #51 (AC4): deploy.sh --preview.
# Preview must report installation changes without applying them: new files
# are marked "+", files identical to the template "=", and existing local
# customizations that differ are flagged as conflicts ("!") that a real
# deployment would preserve rather than overwrite.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-test-preview.XXXXXX")"
GH_LOG="$TMP/gh.log"

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

# --- mocked gh (records every call; never touches the network) -------------
MOCK_BIN="$TMP/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$*" in
  *nameWithOwner*) echo "acme/fixture" ;;
  *defaultBranchRef*) echo "trunk" ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/gh"

# Target fixture: a local repo with one customized component (AGENTS.md),
# one component identical to the template (the whole docs/ directory, since
# deploy.sh copies and compares components as whole items), and everything
# else missing.
FIX="$TMP/target"
mkdir -p "$FIX"
git init -q "$FIX"
git -C "$FIX" symbolic-ref HEAD refs/heads/trunk
printf '# my customized agents file\n' > "$FIX/AGENTS.md"
cp -R "$REPO_ROOT/docs" "$FIX/docs"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "init"
COMMITS_BEFORE=$(git -C "$FIX" rev-list --count HEAD)

OUT="$TMP/preview.txt"
( cd "$REPO_ROOT" && PATH="$MOCK_BIN:$PATH" ANTHROPIC_AUTH_TOKEN= \
    bash deploy.sh --preview "$FIX" ) > "$OUT" 2>&1
PREVIEW_EXIT=$?

echo "== preview report =="
# --- conflict reporting is explicit ------------------------------------------
check "preview reports the new component as '+'" \
  grep -q '^  + setup\.sh$' "$OUT"
check "preview reports identical component as '='" \
  grep -q '^  = docs$' "$OUT"
check "preview flags the customized component as a conflict '!'" \
  grep -q '^  ! AGENTS\.md$' "$OUT"
check "preview states conflicts keep the local version" \
  sh -c 'grep -q "保留本地" "$1"' sh "$OUT"

# --- preview must not modify the target ---------------------------------------
check "preview exits 0" test "$PREVIEW_EXIT" -eq 0
check "preview copies nothing (setup.sh absent)" test ! -e "$FIX/setup.sh"
check "preview preserves the customized AGENTS.md byte-for-byte" \
  sh -c 'test "$(cat "$1")" = "# my customized agents file"' sh "$FIX/AGENTS.md"
check "preview creates no deploy branch" \
  sh -c '! git -C "$1" rev-parse --verify --quiet chore/agent-dev-template' sh "$FIX"
check "preview stays on the original branch" \
  sh -c 'test "$(git -C "$1" rev-parse --abbrev-ref HEAD)" = trunk' sh "$FIX"
check "preview adds no commit" \
  sh -c 'test "$(git -C "$1" rev-list --count HEAD)" = "$2"' sh "$FIX" "$COMMITS_BEFORE"
check "preview leaves no staged change" \
  sh -c 'git -C "$1" diff --cached --quiet' sh "$FIX"

# --- a real (non-preview) deploy still works afterwards ----------------------
( cd "$REPO_ROOT" && PATH="$MOCK_BIN:$PATH" ANTHROPIC_AUTH_TOKEN= \
    bash deploy.sh "$FIX" ) > "$TMP/deploy.txt" 2>&1 || true
check "deploy after preview still copies missing components" \
  test -f "$FIX/setup.sh"
check "deploy after preview still preserves the customization" \
  sh -c 'test "$(cat "$1")" = "# my customized agents file"' sh "$FIX/AGENTS.md"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
