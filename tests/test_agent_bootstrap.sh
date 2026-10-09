#!/usr/bin/env bash
# Acceptance tests for issue #12: bootstrap and verify repository
# instructions and skills for each agent role (specify / implement / review).
#
# Covers:
#   - role manifest defines instructions, artifacts, skills, tools per role
#   - repository skills discoverable for Claude Code and Codex (synced)
#   - Spec Kit integration config lists claude and codex
#   - preflight verifies files, skill metadata, scripts, tools, working
#     directory and stops with actionable errors (missing context, wrong
#     working directory, startup/tool failures, role selection)
#   - run records capture role, model, instruction revision and skill hashes
#     without exposing secrets, and distinguish discovery from invocation
#   - project-specific skills are picked up by the sync mechanism
#
# Run: bash tests/test_agent_bootstrap.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="scripts/agent-preflight.sh"
SYNC="scripts/sync-skills.sh"
ROLES_JSON=".agent/roles.json"

failures=0

ok()   { echo "ok - $1"; }
bad()  { echo "FAIL - $1${2:+ -- $2}"; failures=$((failures + 1)); }

check() { # check <description> <command...> -- passes when command succeeds
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

neg_check() { # neg_check <description> <command...> -- passes when command fails
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-bootstrap.XXXXXX")"
LAST_OUT="$WORK/last.out"
LAST_RC="$WORK/last.rc"
trap 'rm -rf "$WORK"' EXIT

run() { # run <cmd...> -- capture combined output and exit code
  "$@" > "$LAST_OUT" 2>&1
  echo $? > "$LAST_RC"
}

run_cd() { # run_cd <dir> <cmd...> -- run with cwd <dir>
  d=$1; shift
  ( cd "$d" && "$@" > "$LAST_OUT" 2>&1; echo $? > "$LAST_RC" )
}

rc0() { [ "$(cat "$LAST_RC")" -eq 0 ]; }
rc_bad() { [ "$(cat "$LAST_RC")" -ne 0 ]; }
out_grep() { grep -Eq "$1" "$LAST_OUT"; }
out_fgrep() { grep -Fq "$1" "$LAST_OUT"; }

IN_DIR=""
expect_ok() { # expect_ok <description> <cmd...>  (runs in $IN_DIR when set)
  desc=$1; shift
  if [ -n "$IN_DIR" ]; then run_cd "$IN_DIR" "$@"; else run "$@"; fi
  if rc0; then ok "$desc"; else bad "$desc" "exit $(cat "$LAST_RC"): $(tail -3 "$LAST_OUT" | tr '\n' ' ')"; fi
}

expect_fail() { # expect_fail <description> <pattern> <cmd...>  (runs in $IN_DIR when set)
  desc=$1; pat=$2; shift 2
  if [ -n "$IN_DIR" ]; then run_cd "$IN_DIR" "$@"; else run "$@"; fi
  if rc_bad && out_grep "$pat"; then ok "$desc"; else bad "$desc" "exit $(cat "$LAST_RC"): $(tail -3 "$LAST_OUT" | tr '\n' ' ')"; fi
}

check_nonempty() { # check_nonempty <description> <value>
  desc=$1; val=$2
  if [ -n "$val" ]; then ok "$desc"; else bad "$desc"; fi
}

hash256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

make_copy() { # make_copy <name> -- copy repo into $WORK/<name>, fresh git
  dst="$WORK/$1"
  mkdir -p "$dst"
  cp -R "$REPO_ROOT/." "$dst/"
  rm -rf "$dst/.git" "$dst/.agent/runs"
  git -C "$dst" init -q
  git -C "$dst" add -A
  git -C "$dst" -c user.name=Test -c user.email=test@example.com commit -qm "test fixture"
}

role_block() { # role_block <role> -- print the role object from roles.json
  sed -n "/^    \"$1\": {/,/^    }/p" "$REPO_ROOT/$ROLES_JSON"
}

role_list() { # role_list <role> <key> -- space-separated array values
  role_block "$1" | sed -n "s/^ *\"$2\": \[\(.*\)\],\{0,1\}\$/\1/p" \
    | tr ',' '\n' | sed 's/^ *"//; s/" *$//' | tr '\n' ' '
}

ALL_SKILLS=
collect_all_skills() {
  for r in specify implement review; do
    for s in $(role_list "$r" skills); do
      case " $ALL_SKILLS " in *" $s "*) ;; *) ALL_SKILLS="$ALL_SKILLS $s" ;; esac
    done
  done
}

echo "== manifest: roles, skills, tools (AC1)"
check "role manifest exists at $ROLES_JSON" test -f "$REPO_ROOT/$ROLES_JSON"

if [ -f "$REPO_ROOT/$ROLES_JSON" ]; then
  for r in specify implement review; do
    check "role '$r' defined" grep -Fq "\"$r\": {" "$REPO_ROOT/$ROLES_JSON"
    check_nonempty "role '$r' defines instructions" "$(role_list "$r" instructions)"
    check_nonempty "role '$r' defines artifacts" "$(role_list "$r" artifacts)"
    check_nonempty "role '$r' defines scripts" "$(role_list "$r" scripts)"
    check_nonempty "role '$r' defines skills" "$(role_list "$r" skills)"
    check_nonempty "role '$r' defines tools" "$(role_list "$r" tools)"
  done
  check "manifest documents claude skill source" \
    grep -Fq '".claude/skills"' "$REPO_ROOT/$ROLES_JSON"
  check "manifest documents codex skill source" \
    grep -Fq '".codex/skills"' "$REPO_ROOT/$ROLES_JSON"
  check "manifest documents invocation syntax for claude and codex" \
    sh -c "grep -Fq 'invocation_syntax' '$REPO_ROOT/$ROLES_JSON' && grep -Fq '\"claude\"' '$REPO_ROOT/$ROLES_JSON' && grep -Fq '\"codex\"' '$REPO_ROOT/$ROLES_JSON'"
fi

echo "== dual-harness skill mapping and sync state (AC2, AC3)"
collect_all_skills
for s in $ALL_SKILLS; do
  check "skill '$s' discoverable by Claude Code" test -f "$REPO_ROOT/.claude/skills/$s/SKILL.md"
  check "skill '$s' discoverable by Codex" test -f "$REPO_ROOT/.codex/skills/$s/SKILL.md"
  check "skill '$s' has name frontmatter" \
    sh -c "sed -n '/^---\$/,/^---\$/p' '$REPO_ROOT/.claude/skills/$s/SKILL.md' | grep -q '^name:'"
  check "skill '$s' has description frontmatter" \
    sh -c "sed -n '/^---\$/,/^---\$/p' '$REPO_ROOT/.claude/skills/$s/SKILL.md' | grep -q '^description:'"
  check "skill '$s' identical in .claude and .codex" \
    cmp -s "$REPO_ROOT/.claude/skills/$s/SKILL.md" "$REPO_ROOT/.codex/skills/$s/SKILL.md"
done

check "spec-kit integration config lists claude" \
  grep -Fq '"claude"' "$REPO_ROOT/.specify/integration.json"
check "spec-kit integration config lists codex" \
  grep -Fq '"codex"' "$REPO_ROOT/.specify/integration.json"

MANIFEST="$REPO_ROOT/.specify/integrations/codex.manifest.json"
check "codex integration manifest exists" test -f "$MANIFEST"
if [ -f "$MANIFEST" ]; then
  entries=$(sed -n 's/^    "\([^"]*\)": "\([0-9a-f]\{64\}\)".*/\1 \2/p' "$MANIFEST")
  manifest_files_ok=0
  manifest_count=0
  OLDIFS=$IFS
  IFS='
'
  for e in $entries; do
    manifest_count=$((manifest_count + 1))
    p=${e% *}; h=${e#* }
    if [ "$h" = "$(hash256 "$REPO_ROOT/$p")" ]; then
      :
    else
      manifest_files_ok=1
    fi
  done
  IFS=$OLDIFS
  [ "$manifest_count" -gt 0 ] && [ "$manifest_files_ok" -eq 0 ]
  check "codex manifest hashes match synced files" test $? -eq 0
  [ "$manifest_count" -eq "$(ls "$REPO_ROOT/.codex/skills" | wc -l | tr -d ' ')" ]
  check "codex manifest covers every synced skill" test $? -eq 0
fi

echo "== role selection and happy path (AC1, AC4)"
COPY_A="$WORK/copy-a"
make_copy copy-a
IN_DIR="$COPY_A"

expect_fail "preflight without arguments prints usage" "Usage:" \
  bash "$COPY_A/$PREFLIGHT"
expect_fail "preflight with unknown role lists valid roles" "valid roles" \
  bash "$COPY_A/$PREFLIGHT" verify deployer
expect_fail "note-invocation with unknown role is rejected" "valid roles" \
  bash "$COPY_A/$PREFLIGHT" note-invocation deployer some-skill

for r in specify implement review; do
  expect_ok "verify '$r' passes in a bootstrapped copy" \
    bash "$COPY_A/$PREFLIGHT" verify "$r"
done

echo "== run record content, model, secrets (AC5)"
REC=$(ls "$COPY_A/.agent/runs/preflight-implement-"*.json 2>/dev/null | head -1)
check "verify writes a run record for the role" test -n "$REC"
if [ -n "$REC" ]; then
  check "record captures role" grep -Fq '"role": "implement"' "$REC"
  check "record captures model" grep -Fq '"model":' "$REC"
  check "record captures instruction revision" grep -Fq '"instruction_revision"' "$REC"
  check "record hashes AGENTS.md instructions" grep -Fq '"AGENTS.md"' "$REC"
  check "record captures discovered skill with hash" grep -Fq '"skill": "speckit-implement"' "$REC"
  check "record distinguishes discovery from invocation evidence" grep -Fq '"invoked": []' "$REC"
fi

run_cd "$COPY_A" env AGENT_MODEL=test-model-xyz bash "$COPY_A/$PREFLIGHT" verify implement
REC2=$(ls -t "$COPY_A/.agent/runs/preflight-implement-"*.json | head -1)
check "record captures AGENT_MODEL selection" grep -Fq 'test-model-xyz' "$REC2"

SENTINEL="sk-sentinel-DO-NOT-LEAK-1234"
run_cd "$COPY_A" env ANTHROPIC_AUTH_TOKEN="$SENTINEL" ANTHROPIC_API_KEY="sk-ant-$SENTINEL" \
  GITHUB_TOKEN="ghp-$SENTINEL" bash "$COPY_A/$PREFLIGHT" verify review
REC3=$(ls -t "$COPY_A/.agent/runs/preflight-review-"*.json | head -1)
if grep -rFq "$SENTINEL" "$COPY_A/.agent/runs" || grep -Fq "$SENTINEL" "$LAST_OUT"; then
  bad "run record and output never expose credential values"
else
  ok "run record and output never expose credential values"
fi
[ -n "$REC3" ]; check "secret-carrying run still records the role" test $? -eq 0

echo "== missing context fails with actionable errors (AC4, AC6)"
COPY_B="$WORK/copy-b"
make_copy copy-b
IN_DIR="$COPY_B"

rm "$COPY_B/AGENTS.md"
expect_fail "missing AGENTS.md is reported" "AGENTS.md" \
  bash "$COPY_B/$PREFLIGHT" verify implement
git -C "$COPY_B" checkout -- AGENTS.md

rm "$COPY_B/.specify/templates/spec-template.md"
expect_fail "missing role artifact is reported" "spec-template.md" \
  bash "$COPY_B/$PREFLIGHT" verify specify
git -C "$COPY_B" checkout -- .specify/templates/spec-template.md

rm "$COPY_B/.claude/skills/speckit-implement/SKILL.md"
expect_fail "missing required skill is reported" "speckit-implement" \
  bash "$COPY_B/$PREFLIGHT" verify implement
git -C "$COPY_B" checkout -- .claude/skills/speckit-implement/SKILL.md

chmod -x "$COPY_B/.specify/scripts/bash/common.sh"
expect_fail "non-executable supporting script is reported" "not executable" \
  bash "$COPY_B/$PREFLIGHT" verify specify
chmod +x "$COPY_B/.specify/scripts/bash/common.sh"

sed 's/^name:/broken-name:/' "$COPY_B/.claude/skills/speckit-implement/SKILL.md" > "$WORK/tmp.skill"
mv "$WORK/tmp.skill" "$COPY_B/.claude/skills/speckit-implement/SKILL.md"
expect_fail "skill with broken frontmatter metadata is reported" "frontmatter" \
  bash "$COPY_B/$PREFLIGHT" verify implement
git -C "$COPY_B" checkout -- .claude/skills/speckit-implement/SKILL.md

cp "$COPY_B/.claude/skills/speckit-implement/SKILL.md" "$WORK/keep.md"
printf 'drift\n' >> "$COPY_B/.codex/skills/speckit-implement/SKILL.md"
expect_fail "out-of-sync codex skill copy is reported with sync hint" "sync-skills" \
  bash "$COPY_B/$PREFLIGHT" verify implement
cp "$WORK/keep.md" "$COPY_B/.codex/skills/speckit-implement/SKILL.md"

rm "$COPY_B/.agent/roles.json"
expect_fail "missing role manifest is reported" "roles.json" \
  bash "$COPY_B/$PREFLIGHT" verify implement
git -C "$COPY_B" checkout -- .agent/roles.json

echo "== wrong working directory fails with actionable error (AC4, AC6)"
run_cd "$WORK" bash "$COPY_B/$PREFLIGHT" verify implement
if rc_bad && out_grep "repository root"; then ok "run outside the repository is rejected"; else bad "run outside the repository is rejected"; fi
run_cd "$COPY_B/docs" bash "$COPY_B/$PREFLIGHT" verify implement
if rc_bad && out_grep "repository root"; then ok "run from a subdirectory is rejected"; else bad "run from a subdirectory is rejected"; fi

echo "== startup failures: missing tools (AC4, AC6)"
TOOLBIN="$WORK/toolbin"
mkdir -p "$TOOLBIN"
for t in /bin/cat /bin/date /bin/mkdir /usr/bin/cmp /usr/bin/dirname /usr/bin/grep /usr/bin/sed /usr/bin/tr; do
  [ -x "$t" ] && ln -sf "$t" "$TOOLBIN/$(basename "$t")"
done
add_tools() {
  for t in "$@"; do
    p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$TOOLBIN/$t"
  done
}
drop_tool() { rm -f "$TOOLBIN/$1"; }

add_tools git gh node npm; drop_tool git
expect_fail "missing required tool git is reported" "required tool.*git" \
  env PATH="$TOOLBIN" /bin/bash "$COPY_B/$PREFLIGHT" verify implement
drop_tool gh
add_tools git
expect_fail "missing required tool gh is reported" "required tool.*gh" \
  env PATH="$TOOLBIN" /bin/bash "$COPY_B/$PREFLIGHT" verify implement
drop_tool node
expect_fail "missing required tool node is reported" "required tool.*node" \
  env PATH="$TOOLBIN" /bin/bash "$COPY_B/$PREFLIGHT" verify implement

echo "== invocation evidence recording (AC3, AC5)"
expect_fail "note-invocation without a prior run record is rejected" "verify" \
  bash "$COPY_B/$PREFLIGHT" note-invocation implement speckit-implement

IN_DIR="$COPY_A"
expect_ok "note-invocation records an explicit skill invocation" \
  bash "$COPY_A/$PREFLIGHT" note-invocation implement speckit-implement
JSONL="$COPY_A/.agent/runs/invocations.jsonl"
check "invocation evidence lands in invocations.jsonl" \
  sh -c "grep -Fq 'speckit-implement' '$JSONL' && grep -Fq '\"role\":\"implement\"' '$JSONL'"
expect_fail "note-invocation rejects skills outside the role mapping" "speckit-analyze" \
  bash "$COPY_A/$PREFLIGHT" note-invocation implement speckit-analyze

echo "== sync mechanism and project-specific skills (AC2, AC6)"
COPY_C="$WORK/copy-c"
make_copy copy-c
IN_DIR="$COPY_C"

mkdir -p "$COPY_C/.claude/skills/proj-custom"
cat > "$COPY_C/.claude/skills/proj-custom/SKILL.md" <<'EOS'
---
name: proj-custom
description: Project-specific acceptance test skill
---
Body.
EOS
expect_ok "sync-skills syncs a new project-specific skill" \
  bash "$COPY_C/$SYNC"
check "new skill becomes discoverable by Codex" \
  cmp -s "$COPY_C/.claude/skills/proj-custom/SKILL.md" "$COPY_C/.codex/skills/proj-custom/SKILL.md"
check "sync refreshes codex manifest with new skill" \
  grep -Fq 'proj-custom' "$COPY_C/.specify/integrations/codex.manifest.json"

expect_ok "sync-skills is idempotent" bash "$COPY_C/$SYNC"
expect_ok "sync-skills --check passes when in sync" \
  bash "$COPY_C/$SYNC" --check
git -C "$COPY_C" add -A
git -C "$COPY_C" -c user.name=Test -c user.email=test@example.com commit -qm "synced"
bash "$COPY_C/$SYNC" >/dev/null 2>&1
check "re-running sync produces no drift" sh -c "[ -z \"\$(git -C '$COPY_C' status --porcelain)\" ]"

printf 'drift\n' >> "$COPY_C/.claude/skills/speckit-specify/SKILL.md"
expect_fail "sync-skills --check detects drift" "speckit-specify" \
  bash "$COPY_C/$SYNC" --check
expect_ok "sync-skills repairs drift" bash "$COPY_C/$SYNC"
expect_ok "sync-skills --check passes after repair" bash "$COPY_C/$SYNC" --check

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
