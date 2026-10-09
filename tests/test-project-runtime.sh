#!/usr/bin/env bash
# Acceptance tests for issue #14: machine-readable project runtime
# configuration and fail-fast execution prerequisites.
#
# Covers:
#   - .agent/project.json defines runtime, lockfile, install/build/test/
#     lint/typecheck commands, pinned agent tooling, integrations and model
#     auth env names; AGENTS.md/INSTALL.md document the setup path
#   - configuration is validated before autonomous development:
#     'agent-preflight.sh verify-project' rejects missing commands,
#     unresolved placeholders, unpinned tooling, unknown integrations and
#     missing/unsupported lockfiles; role 'verify' refuses invalid config
#   - scripts/bootstrap-env.sh reproduces the environment: lockfile-driven
#     dependency install, pinned Claude Code CLI, integration/auth and
#     non-interactive verification, all failing fast instead of hanging
#   - workflows bootstrap through the script; setup-node versions derive from
#     the trusted .agent/project.json (no hardcoded literals); unpinned CLI
#     installs are gone and the pr-review merge decider
#     (scripts/review-verdict.sh) is intact
#   - failures: dependency install, pinned tooling install, runtime command
#     execution errors; non-Node projects use their configured install command
#
# Run: bash tests/test-project-runtime.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="scripts/agent-preflight.sh"
BOOT="scripts/bootstrap-env.sh"
PROJECT=".agent/project.json"

failures=0

ok()   { echo "ok - $1"; }
bad()  { echo "FAIL - $1${2:+ -- $2}"; failures=$((failures + 1)); }

check() { # check <description> <command...> -- passes when command succeeds
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/adt-project-runtime.XXXXXX")"
OUT="$WORK/out"
RC="$WORK/rc"
trap 'rm -rf "$WORK"' EXIT

MOCK_BIN="$WORK/bin"
MOCK_LOG="$WORK/mock.log"
: > "$MOCK_LOG"
export MOCK_LOG

# --- mocked toolchain (records calls; rc injectable via env knobs) -----------
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/npm" <<'EOF'
#!/usr/bin/env bash
set -u
echo "npm $*" >> "$MOCK_LOG"
for a in "$@"; do
  [ "$a" = "-g" ] && exit "${NPM_GLOBAL_RC:-0}"
done
exit "${NPM_INSTALL_RC:-0}"
EOF

cat > "$MOCK_BIN/node" <<'EOF'
#!/usr/bin/env bash
set -u
echo "node $*" >> "$MOCK_LOG"
[ "${1:-}" = "--version" ] || exit 0
[ "${NODE_RC:-0}" -eq 0 ] || exit "${NODE_RC}"
echo "${NODE_VERSION_OUT:-v22.11.0}"
EOF

cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$MOCK_LOG"
case "$1 ${2:-}" in
  "auth status") exit "${GH_AUTH_RC:-0}" ;;
esac
exit 0
EOF

cat > "$MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -u
echo "claude $*" >> "$MOCK_LOG"
exit 0
EOF

for m in yarn pnpm pip; do
  cat > "$MOCK_BIN/$m" <<EOF
#!/usr/bin/env bash
set -u
echo "$m \$*" >> "$MOCK_LOG"
exit 0
EOF
done
chmod +x "$MOCK_BIN/"*

FULL_PATH="$MOCK_BIN:$PATH"  # mocks shadow the real toolchain

# Hermetic PATH for the "missing tool" runs: the mocked toolchain plus a
# directory holding ONLY the POSIX utilities bootstrap-env.sh and
# agent-preflight.sh need, so an ambient gh/claude/node installed in the
# system (e.g. /usr/bin) can never satisfy a "not found in PATH" check.
HERMETIC_BIN="$WORK/hermetic-bin"
mkdir -p "$HERMETIC_BIN"
for t in bash cat dirname grep printenv sed touch tr; do
  p="$(command -v "$t")" && ln -s "$p" "$HERMETIC_BIN/$t"
done
BARE_PATH="$MOCK_BIN:$HERMETIC_BIN"

TOKEN="sk-bootstrap-sentinel-token"

run_boot() { # run_boot <dir> [args...] -> rc in $RC, output in $OUT
  d=$1; shift
  ( cd "$d" && PATH="$FULL_PATH" ANTHROPIC_AUTH_TOKEN="$TOKEN" \
      bash "$d/$BOOT" "$@" ) > "$OUT" 2>&1
  echo $? > "$RC"
}

run_boot_noauth() { # like run_boot but with model auth env unset
  d=$1; shift
  ( cd "$d" && env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
      PATH="$FULL_PATH" bash "$d/$BOOT" "$@" ) > "$OUT" 2>&1
  echo $? > "$RC"
}

run_boot_bare() { # like run_boot but isolated from the real toolchain
  d=$1; shift
  ( cd "$d" && PATH="$BARE_PATH" ANTHROPIC_AUTH_TOKEN="$TOKEN" \
      bash "$d/$BOOT" "$@" ) > "$OUT" 2>&1
  echo $? > "$RC"
}

pf() { # pf <dir> [args...] -> run preflight in <dir>
  d=$1; shift
  ( cd "$d" && bash "$d/$PREFLIGHT" "$@" ) > "$OUT" 2>&1
  echo $? > "$RC"
}

pf_tool() { # pf_tool <dir> [args...] -> preflight with mocked tools
  d=$1; shift
  ( cd "$d" && PATH="$FULL_PATH" bash "$d/$PREFLIGHT" "$@" ) > "$OUT" 2>&1
  echo $? > "$RC"
}

rc0()      { [ "$(cat "$RC")" -eq 0 ]; }
rc_bad()   { [ "$(cat "$RC")" -ne 0 ]; }
out_grep() { grep -Eq "$1" "$OUT"; }
log_line()  { grep -Fxq -- "$1" "$MOCK_LOG"; }
log_has()   { grep -Fq -- "$1" "$MOCK_LOG"; }
file_has()  { grep -Fq -- "$1" "$2"; }

make_copy() { # make_copy <name> -- copy TRACKED files into $WORK/<name>, fresh git
  dst="$WORK/$1"
  mkdir -p "$dst"
  # Export the committed tree only: an untracked lockfile in the working
  # tree (e.g. a stray package-lock.json) must not flip the lockfile
  # auto-detection tests below.
  git -C "$REPO_ROOT" archive HEAD | tar -x -C "$dst"
  git -C "$dst" init -q
  git -C "$dst" add -A
  git -C "$dst" -c user.name=Test -c user.email=test@example.com commit -qm "test fixture"
}

cfg() { # cfg <copy> <key> <value> -- replace a single-line string value
  cfg_file="$WORK/$1/$PROJECT"
  sed "s|\"$2\": \"[^\"]*\"|\"$2\": \"$3\"|" "$cfg_file" > "$cfg_file.tmp" \
    && mv "$cfg_file.tmp" "$cfg_file"
}

cfg_arr() { # cfg_arr <copy> <key> <array-literal> -- replace a JSON array
  cfg_file="$WORK/$1/$PROJECT"
  sed "s|\"$2\": \[.*\]|\"$2\": [$3]|" "$cfg_file" > "$cfg_file.tmp" \
    && mv "$cfg_file.tmp" "$cfg_file"
}

cfg_pin() { sed -n 's/.*"claude_code": "\([^"]*\)".*/\1/p' "$REPO_ROOT/$PROJECT" | sed -n 1p; }

echo "== machine-readable project configuration (AC1)"
check "project configuration exists at $PROJECT" test -f "$REPO_ROOT/$PROJECT"
if [ -f "$REPO_ROOT/$PROJECT" ]; then
  for key in name version lockfile install build test lint typecheck claude_code; do
    check "configuration defines '$key'" grep -Eq "\"$key\":" "$REPO_ROOT/$PROJECT"
  done
  check "configuration declares integrations" grep -Fq '"integrations"' "$REPO_ROOT/$PROJECT"
  check "configuration declares model auth env names" grep -Fq '"any_of_env"' "$REPO_ROOT/$PROJECT"
  PIN="$(cfg_pin)"
  case "$PIN" in
    [0-9]*.[0-9]*) ok "claude code cli pinned to exact version ($PIN)" ;;
    '') bad "claude code cli pinned to exact version" ;;
    *) bad "claude code cli pinned to exact version" "got '$PIN'" ;;
  esac
  RT_VER="$(sed -n 's/.*"version": "\([0-9][0-9.]*\)".*/\1/p' "$REPO_ROOT/$PROJECT" | sed -n 1p)"
  check "runtime pin satisfies the claude-code engine (node >= 22)" \
    sh -c 'test "${1%%.*}" -ge 22' sh "$RT_VER"
fi
check "package-lock.json is committed" \
  git -C "$REPO_ROOT" ls-files --error-unmatch package-lock.json
check "runtime.lockfile declares the committed package-lock.json" \
  grep -Fq '"lockfile": "package-lock.json"' "$REPO_ROOT/$PROJECT"
check "AGENTS.md has no unresolved project-info placeholder" \
  sh -c "! grep -Fq '待填' '$REPO_ROOT/AGENTS.md'"
check "AGENTS.md points to the machine-readable configuration" \
  grep -Fq '.agent/project.json' "$REPO_ROOT/AGENTS.md"
check "INSTALL.md documents the project setup path" \
  grep -Fq '.agent/project.json' "$REPO_ROOT/INSTALL.md"

echo "== workflow wiring: pinned bootstrap, merge decider intact"
for wf in claude.yml agent-sweep.yml pr-review.yml; do
  check "$wf bootstraps via scripts/bootstrap-env.sh" \
    grep -Fq "scripts/bootstrap-env.sh" "$REPO_ROOT/.github/workflows/$wf"
  check "$wf has no unpinned claude-code install" \
    sh -c "! grep -Fq 'npm install -g @anthropic-ai/claude-code' '$REPO_ROOT/.github/workflows/$wf'"
done
# The runner must provision exactly what the trusted bootstrap accepts: every
# workflow derives its setup-node version from .agent/project.json instead of
# a hardcoded literal, so a pin bump (on main or in a PR) can never desync
# provisioning from enforcement -- the PR that changes the pin passes its own
# audit under the base revision's pin (issue #57).
for wf in "$REPO_ROOT"/.github/workflows/*.yml; do
  grep -Fq 'node-version:' "$wf" || continue
  w="$(basename "$wf")"
  check "$w has no hardcoded node-version literal" \
    sh -c '! grep -Eq "node-version: \"?[0-9]" "$1"' sh "$wf"
  check "$w resolves the pin from .agent/project.json runtime.version" \
    sh -c 'grep -A3 "id: node_pin" "$1" | grep -Fq "runtime.version"' sh "$wf"
  check "$w setup-node consumes the resolved pin" \
    sh -c 'grep -Fq -- "$2" "$1"' sh "$wf" \
    'node-version: ${{ steps.node_pin.outputs.version }}'
  pin_at="$(grep -n -m1 -F 'id: node_pin' "$wf" | cut -d: -f1)"
  sn_at="$(grep -n -m1 -F 'uses: actions/setup-node@v4' "$wf" | cut -d: -f1)"
  check "$w resolves the pin before setup-node provisions" \
    sh -c 'test -n "$1" && test -n "$2" && test "$1" -lt "$2"' sh "$pin_at" "$sn_at"
done
# pr-review reads the pin from the trusted base-SHA checkout at the workspace
# root (issue #19): the control plane being merged INTO, not the PR under
# review, decides the runtime the audit provisions.
PR_WF="$REPO_ROOT/.github/workflows/pr-review.yml"
base_at="$(grep -n -m1 -F 'github.event.pull_request.base.sha' "$PR_WF" | cut -d: -f1)"
pin_at="$(grep -n -m1 -F 'id: node_pin' "$PR_WF" | cut -d: -f1)"
check "pr-review derives the pin from the trusted base checkout" \
  sh -c 'test -n "$1" && test -n "$2" && test "$1" -lt "$2"' sh "$base_at" "$pin_at"
check "pr-review pin step reads the root copy, not the reviewed/ copy" \
  sh -c '! grep -A3 "id: node_pin" "$1" | grep -Fq "reviewed/.agent/project.json"' sh "$PR_WF"
check "pr-review.yml still delegates merging to review-verdict.sh" \
  grep -Fq "scripts/review-verdict.sh" "$REPO_ROOT/.github/workflows/pr-review.yml"

echo "== configuration validation (AC2)"
COPY_A="$WORK/copy-a"
make_copy copy-a

pf "$COPY_A" verify-project
if rc0; then ok "valid configuration passes verify-project"; else bad "valid configuration passes verify-project" "exit $(cat "$RC"): $(tail -3 "$OUT" | tr '\n' ' ')"; fi

pf "$COPY_A"
check "preflight usage documents verify-project" sh -c '[ "$1" != 0 ] && grep -Fq "verify-project" "$2"' sh "$(cat "$RC")" "$OUT"

pf "$REPO_ROOT" verify-project
if rc0; then ok "repository configuration validates in place"; else bad "repository configuration validates in place" "exit $(cat "$RC")"; fi

rm "$COPY_A/$PROJECT"
pf "$COPY_A" verify-project
if rc_bad && out_grep "project.json"; then ok "missing configuration file is rejected"; else bad "missing configuration file is rejected"; fi
git -C "$COPY_A" checkout -- .agent/project.json

cfg copy-a test ""
pf "$COPY_A" verify-project
if rc_bad && out_grep "commands.test"; then ok "missing required test command is rejected"; else bad "missing required test command is rejected"; fi
git -C "$COPY_A" checkout -- .agent/project.json

cfg copy-a install "npm install # TODO"
pf "$COPY_A" verify-project
if rc_bad && out_grep "placeholder"; then ok "placeholder install command is rejected"; else bad "placeholder install command is rejected"; fi

cfg copy-a build "npm run build # TODO"
pf "$COPY_A" verify-project
if rc_bad && out_grep "placeholder"; then ok "placeholder in optional command is rejected"; else bad "placeholder in optional command is rejected"; fi
git -C "$COPY_A" checkout -- .agent/project.json

cfg copy-a name ""
pf "$COPY_A" verify-project
if rc_bad && out_grep "runtime.name"; then ok "missing runtime name is rejected"; else bad "missing runtime name is rejected"; fi
git -C "$COPY_A" checkout -- .agent/project.json

cfg copy-a version ""
pf "$COPY_A" verify-project
if rc_bad && out_grep "runtime.version"; then ok "node runtime without pinned version is rejected"; else bad "node runtime without pinned version is rejected"; fi
git -C "$COPY_A" checkout -- .agent/project.json

cfg copy-a lockfile "yarn.lock"
pf "$COPY_A" verify-project
if rc_bad && out_grep "yarn.lock"; then ok "declared but missing lockfile is rejected"; else bad "declared but missing lockfile is rejected"; fi
git -C "$COPY_A" checkout -- .agent/project.json

touch "$COPY_A/Gemfile.lock"
cfg copy-a lockfile "Gemfile.lock"
pf "$COPY_A" verify-project
if rc_bad && out_grep "unsupported"; then ok "unsupported lockfile type is rejected"; else bad "unsupported lockfile type is rejected"; fi
rm "$COPY_A/Gemfile.lock"
git -C "$COPY_A" checkout -- .agent/project.json

cfg copy-a claude_code "latest"
pf "$COPY_A" verify-project
if rc_bad && out_grep "claude_code"; then ok "unpinned claude code version is rejected"; else bad "unpinned claude code version is rejected"; fi
git -C "$COPY_A" checkout -- .agent/project.json

cfg_arr copy-a integrations '"bogus"'
pf "$COPY_A" verify-project
if rc_bad && out_grep "claude"; then ok "unknown integration is rejected"; else bad "unknown integration is rejected"; fi
git -C "$COPY_A" checkout -- .agent/project.json

cfg_arr copy-a any_of_env ''
pf "$COPY_A" verify-project
if rc_bad && out_grep "any_of_env"; then ok "empty model auth env list is rejected"; else bad "empty model auth env list is rejected"; fi
git -C "$COPY_A" checkout -- .agent/project.json

echo "== role preflight enforces configuration (AC2)"
cfg copy-a test ""
pf_tool "$COPY_A" verify implement
if rc_bad && out_grep "project configuration"; then ok "role verify refuses invalid project configuration"; else bad "role verify refuses invalid project configuration" "exit $(cat "$RC")"; fi
git -C "$COPY_A" checkout -- .agent/project.json

pf_tool "$COPY_A" verify implement
if rc0; then ok "role verify passes with valid configuration"; else bad "role verify passes with valid configuration" "exit $(cat "$RC"): $(tail -3 "$OUT" | tr '\n' ' ')"; fi

echo "== reproducible bootstrap (AC3)"
PIN="$(cfg_pin)"
: > "$MOCK_LOG"
run_boot "$COPY_A"
if rc0; then ok "bootstrap passes on a valid configuration"; else bad "bootstrap passes on a valid configuration" "exit $(cat "$RC"): $(tail -3 "$OUT" | tr '\n' ' ')"; fi
check "installs the pinned claude code cli" \
  log_has "install -g @anthropic-ai/claude-code@$PIN"
check "committed package-lock.json drives a frozen npm ci install" log_line "npm ci"
if grep -Fq "$TOKEN" "$OUT" || grep -Fq "$TOKEN" "$MOCK_LOG"; then
  bad "bootstrap never prints credential values"
else
  ok "bootstrap never prints credential values"
fi

COPY_N="$WORK/copy-nolock"
make_copy copy-nolock
rm -f "$COPY_N/package-lock.json"
cfg copy-nolock lockfile ""
: > "$MOCK_LOG"
run_boot "$COPY_N"
check "missing lockfile falls back to the configured install command" \
  log_line "npm install"

COPY_L="$WORK/copy-lock"
make_copy copy-lock
touch "$COPY_L/package-lock.json"
: > "$MOCK_LOG"
run_boot "$COPY_L"
check "package-lock.json forces a frozen npm ci install" log_line "npm ci"

COPY_Y="$WORK/copy-yarn"
make_copy copy-yarn
rm -f "$COPY_Y/package-lock.json"
cfg copy-yarn lockfile ""
touch "$COPY_Y/yarn.lock"
: > "$MOCK_LOG"
run_boot "$COPY_Y"
check "yarn.lock auto-detects a frozen yarn install" \
  log_line "yarn install --frozen-lockfile"

: > "$MOCK_LOG"
run_boot "$COPY_A" --check
if rc0; then ok "check mode passes without installing"; else bad "check mode passes without installing" "exit $(cat "$RC")"; fi
check "check mode runs no install commands" sh -c "! grep -q npm '$MOCK_LOG'"

echo "== fail-fast prerequisites (AC4)"
run_boot_noauth "$COPY_A"
if rc_bad && out_grep "ANTHROPIC_AUTH_TOKEN"; then ok "missing model authentication fails fast"; else bad "missing model authentication fails fast" "exit $(cat "$RC")"; fi

GH_AUTH_RC=1
export GH_AUTH_RC
run_boot "$COPY_A"
if rc_bad && out_grep "authenticated"; then ok "unauthenticated gh fails fast"; else bad "unauthenticated gh fails fast"; fi
unset GH_AUTH_RC

mv "$MOCK_BIN/gh" "$WORK/gh.hidden"
run_boot_bare "$COPY_A"
if rc_bad && out_grep "gh not found in PATH"; then ok "missing gh tool fails fast"; else bad "missing gh tool fails fast"; fi
mv "$WORK/gh.hidden" "$MOCK_BIN/gh"

mv "$MOCK_BIN/claude" "$WORK/claude.hidden"
run_boot_bare "$COPY_A"
if rc_bad && out_grep "integration 'claude' missing from PATH"; then ok "missing claude integration fails fast"; else bad "missing claude integration fails fast"; fi
mv "$WORK/claude.hidden" "$MOCK_BIN/claude"

GITHUB_ENV="$WORK/ghenv"
export GITHUB_ENV
: > "$GITHUB_ENV"
run_boot "$COPY_A"
check "non-interactive git env persisted for CI steps" \
  file_has "GIT_TERMINAL_PROMPT=0" "$GITHUB_ENV"
check "non-interactive gh env persisted for CI steps" \
  file_has "GH_PROMPT_DISABLED=1" "$GITHUB_ENV"
unset GITHUB_ENV

NODE_VERSION_OUT=v18.1.0
export NODE_VERSION_OUT
run_boot "$COPY_A"
if rc_bad && out_grep "version mismatch"; then ok "node version mismatch fails fast"; else bad "node version mismatch fails fast"; fi
unset NODE_VERSION_OUT

NODE_VERSION_OUT=v24.1.0
export NODE_VERSION_OUT
run_boot "$COPY_A"
if rc0; then ok "bootstrap succeeds on a machine whose default node is newer than the pin"; else bad "bootstrap succeeds on a machine whose default node is newer than the pin" "exit $(cat "$RC"): $(tail -3 "$OUT" | tr '\n' ' ')"; fi
unset NODE_VERSION_OUT

echo "== non-Node projects (AC3)"
COPY_P="$WORK/copy-py"
make_copy copy-py
cfg copy-py name "python"
cfg copy-py version ""
cfg copy-py install "pip install -e ."
cfg copy-py test "pytest -q"
pf "$COPY_P" verify-project
if rc0; then ok "non-node configuration validates"; else bad "non-node configuration validates" "exit $(cat "$RC"): $(tail -3 "$OUT" | tr '\n' ' ')"; fi

NODE_VERSION_OUT=v18.1.0
export NODE_VERSION_OUT
: > "$MOCK_LOG"
run_boot "$COPY_P"
if rc0; then ok "non-node bootstrap skips the node version gate"; else bad "non-node bootstrap skips the node version gate" "exit $(cat "$RC"): $(tail -3 "$OUT" | tr '\n' ' ')"; fi
unset NODE_VERSION_OUT
check "non-node bootstrap runs the configured install command" log_line "pip install -e ."
check "non-node bootstrap still installs pinned agent tooling" \
  log_has "install -g @anthropic-ai/claude-code@$PIN"

echo "== installation and command execution failures (AC5)"
NPM_INSTALL_RC=1
export NPM_INSTALL_RC
run_boot "$COPY_A"
if rc_bad && out_grep "dependency installation failed"; then ok "dependency installation failure aborts bootstrap"; else bad "dependency installation failure aborts bootstrap"; fi
unset NPM_INSTALL_RC

NPM_GLOBAL_RC=1
export NPM_GLOBAL_RC
run_boot "$COPY_A"
if rc_bad && out_grep "pinned"; then ok "agent tooling install failure aborts bootstrap"; else bad "agent tooling install failure aborts bootstrap"; fi
unset NPM_GLOBAL_RC

NODE_RC=1
export NODE_RC
run_boot "$COPY_A"
if rc_bad && out_grep "runtime check failed"; then ok "runtime command execution error aborts bootstrap"; else bad "runtime command execution error aborts bootstrap"; fi
unset NODE_RC

mv "$MOCK_BIN/node" "$WORK/node.hidden"
run_boot_bare "$COPY_A"
if rc_bad && out_grep "runtime tool node not found in PATH"; then ok "missing runtime tool fails fast"; else bad "missing runtime tool fails fast"; fi
mv "$WORK/node.hidden" "$MOCK_BIN/node"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
