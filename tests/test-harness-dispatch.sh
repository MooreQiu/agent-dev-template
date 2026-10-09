#!/usr/bin/env bash
# Acceptance tests for issue #23: dispatch authorized agent mentions to
# Claude, Codex, Gemini, or OpenCode.
#
# Criteria covered:
#   - mention parsing: each documented @claude/@codex/@gemini/@opencode
#     command recognized from authorized human comments; substring forms
#     (@claude-code, user@claude.com) ignored; repeated identical mentions
#     are fine while distinct mentions are rejected deterministically
#   - harness enablement: AGENT_HARNESSES repo var gates which mentions
#     dispatch (default claude only), so an enabled official Codex
#     integration (openai/codex-action) never double-dispatches
#   - bot filtering and actor allowlist semantics preserved for every
#     harness mention
#   - per-harness model/effort resolution in model-config.sh (extends, not
#     forks, the #9 resolver): comment override > repo var > CLI default,
#     claude-specific aliases rejected for other harnesses, effort enums
#     per harness, effort-less harnesses reject comment overrides and note
#     ignored repo effort
#   - launcher routes: scripts/agent.sh builds validated, supported
#     non-interactive invocations per pinned CLI (gemini uses
#     --approval-mode=yolo, not the deprecated --yolo), passes model and
#     effort, fails fast on missing CLI or missing credentials without
#     ever printing credential values
#   - pinned tooling: .agent/project.json pins every harness CLI, the
#     preflight validates pins for enabled integrations, bootstrap
#     installs exactly the pinned packages for enabled integrations
#   - gemini role-specific context: .gemini/settings.json loads AGENTS.md
#   - workflow wiring: claude.yml recognizes all four mentions, maps
#     AGENT_HARNESSES from vars, consumes the filter's harness verdict,
#     resolves model/effort per harness, preflights the harness, routes
#     every harness through the shared claim + agent-task.sh pipeline
#   - documentation: README/INSTALL/HARNESSES cover the vars, conflict
#     note, and validated flags
#
# Run: bash tests/test-harness-dispatch.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="$REPO_ROOT/scripts/dispatch-filter.sh"
MC="$REPO_ROOT/scripts/model-config.sh"
LAUNCHER="$REPO_ROOT/scripts/agent.sh"
PREFLIGHT="$REPO_ROOT/scripts/agent-preflight.sh"
BOOTSTRAP="$REPO_ROOT/scripts/bootstrap-env.sh"
CLAUDE_YML="$REPO_ROOT/.github/workflows/claude.yml"
PROJECT="$REPO_ROOT/.agent/project.json"
README="$REPO_ROOT/README.md"
INSTALL="$REPO_ROOT/INSTALL.md"
HARNESSES_DOC="$REPO_ROOT/docs/HARNESSES.md"

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+ -- $2}"; failures=$((failures + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ALL_HARNESSES="claude,codex,gemini,opencode"

# ===========================================================================
# dispatch-filter.sh: mention parsing (AC1)
# ===========================================================================
echo "== filter: mention parsing"

run_filter() { # run_filter <event_name> [agent_harnesses]
  FILTER_OUT=$(GITHUB_EVENT_NAME="$1" GITHUB_EVENT_PATH="$TMP/event.json" \
    AGENT_ALLOWED_ACTORS="${FILTER_ACTORS:-}" AGENT_HARNESSES="${2:-}" \
    bash "$FILTER" 2>&1)
  FILTER_RC=$?
}

harness_of() { printf '%s\n' "$FILTER_OUT" | sed -n 's/^harness=//p' | sed -n 1p; }

comment_event() { # comment_event <body> [login]
  cat >"$TMP/event.json" <<EOF
{"action":"created","issue":{"number":23,"labels":[]},"comment":{"body":"$1","user":{"login":"${2:-alice}","type":"User"}},"sender":{"login":"${2:-alice}","type":"User"}}
EOF
}

expect_allow_harness() { # expect_allow_harness <name> <harness>
  if [ "$FILTER_RC" -eq 0 ] && [ "$(harness_of)" = "$2" ]; then
    pass "$1"
  else
    fail "$1" "rc=$FILTER_RC harness=$(harness_of) out=$FILTER_OUT"
  fi
}

expect_deny_msg() { # expect_deny_msg <name> <needle>
  if [ "$FILTER_RC" -ne 0 ]; then
    if [ -z "$2" ] || printf '%s' "$FILTER_OUT" | grep -Fq -- "$2"; then
      pass "$1"
    else
      fail "$1" "deny reason lacks '$2': $FILTER_OUT"
    fi
  else
    fail "$1" "rc=0 (allowed) out=$FILTER_OUT"
  fi
}

for h in claude codex gemini opencode; do
  comment_event "please @$h fix the flaky test"
  run_filter issue_comment "$ALL_HARNESSES"
  expect_allow_harness "human @$h mention dispatches harness $h" "$h"
done

comment_event "please @claude fix the flaky test"
run_filter issue_comment
expect_allow_harness "@claude mention works with default AGENT_HARNESSES" "claude"

for h in codex gemini opencode; do
  comment_event "please @$h fix it"
  run_filter issue_comment ""
  expect_deny_msg "@$h mention denied unless enabled in AGENT_HARNESSES" "AGENT_HARNESSES"
done

comment_event "@codex and @claude please both work on this"
run_filter issue_comment "$ALL_HARNESSES"
expect_deny_msg "distinct mentions in one comment are ambiguous" "exactly one"

comment_event "@codex fix it. cc @codex again for visibility"
run_filter issue_comment "$ALL_HARNESSES"
expect_allow_harness "repeated identical mention is not ambiguous" "codex"

comment_event "see @claude-code docs and mail user@claude.com thanks"
run_filter issue_comment "$ALL_HARNESSES"
expect_deny_msg "substring forms (@claude-code, user@claude.com) are not mentions" ""

comment_event "(@opencode) please take over"
run_filter issue_comment "$ALL_HARNESSES"
expect_allow_harness "mention in parentheses is recognized" "opencode"

comment_event "no agent called out here"
run_filter issue_comment "$ALL_HARNESSES"
expect_deny_msg "comment without any mention is denied" ""

comment_event "hi @codex"
run_filter issue_comment "claude,vagrant"
expect_deny_msg "unknown AGENT_HARNESSES entry fails with supported list" "supported"

# Assignment path: harness is the first enabled entry (deterministic).
cat >"$TMP/event.json" <<'EOF'
{"action":"assigned","issue":{"number":5,"labels":[{"name":"ready-for-agent"}]},"assignee":{"login":"alice","type":"User"},"sender":{"login":"alice","type":"User"}}
EOF
run_filter issues ""
expect_allow_harness "assignment dispatch uses the default harness (claude)" "claude"
run_filter issues "codex,claude"
expect_allow_harness "assignment dispatch uses the first enabled harness" "codex"

# ===========================================================================
# dispatch-filter.sh: bot and allowlist semantics preserved (AC1, AC6)
# ===========================================================================
echo "== filter: bots and allowlist"

comment_event "🤖 @codex 收到，开始处理" "github-actions[bot]"
run_filter issue_comment "$ALL_HARNESSES"
expect_deny_msg "github-actions ack comment mentioning @codex is denied" ""

cat >"$TMP/event.json" <<'EOF'
{"action":"created","issue":{"number":23,"labels":[]},"comment":{"body":"@gemini go","user":{"login":"mooreqiu-agent-dev-bot[bot]","type":"Bot"}},"sender":{"login":"mooreqiu-agent-dev-bot[bot]","type":"Bot"}}
EOF
run_filter issue_comment "$ALL_HARNESSES"
expect_deny_msg "GitHub App bot comment mentioning @gemini is denied" ""

cat >"$TMP/event.json" <<'EOF'
{"action":"edited","issue":{"number":23,"labels":[]},"comment":{"body":"edited to add @opencode","user":{"login":"alice","type":"User"}},"sender":{"login":"alice","type":"User"}}
EOF
run_filter issue_comment "$ALL_HARNESSES"
expect_deny_msg "comment edits are denied" ""

FILTER_ACTORS="alice,bob"
comment_event "hi @codex" "carol"
run_filter issue_comment "$ALL_HARNESSES"
expect_deny_msg "non-allowlisted caller is denied for non-claude harness" "AGENT_ALLOWED_ACTORS"
comment_event "hi @codex" "Alice"
run_filter issue_comment "$ALL_HARNESSES"
expect_allow_harness "allowlisted caller passes case-insensitively" "codex"
FILTER_ACTORS=""

# ===========================================================================
# model-config.sh: per-harness model and effort (AC2, AC5)
# ===========================================================================
echo "== model-config: per-harness resolution"

MC_DEF=""; MC_FLASH=""; MC_EFF=""; MC_BASE=""
MC_CODEX=""; MC_GEMINI=""; MC_OPENCODE=""

run_mc() { # run_mc <harness> <comment-text|-> <trivial 0|1>
  if [ "$2" = "-" ]; then
    : >"$TMP/comment.txt"
  else
    printf '%s\n' "$2" >"$TMP/comment.txt"
  fi
  MC_OUT="$(AGENT_MODEL_DEFAULT="$MC_DEF" AGENT_MODEL_FLASH="$MC_FLASH" \
    AGENT_EFFORT_DEFAULT="$MC_EFF" ANTHROPIC_BASE_URL="$MC_BASE" \
    AGENT_MODEL_CODEX="$MC_CODEX" AGENT_MODEL_GEMINI="$MC_GEMINI" \
    AGENT_MODEL_OPENCODE="$MC_OPENCODE" \
    HARNESS="$1" \
    bash "$MC" --harness "$1" --comment-file "$TMP/comment.txt" --trivial "$3" 2>"$TMP/mc.err")"
  MC_RC=$?
  MC_ERR="$(cat "$TMP/mc.err")"
}

env_value() { printf '%s\n' "$MC_OUT" | sed -n "s/^$1=//p" | sed -n 1p; }

# claude behavior is byte-identical with and without --harness (AC5).
MC_DEF="repo-normal"; MC_FLASH="repo-flash"; MC_EFF="medium"; MC_BASE=""
run_mc claude "@claude model=opus effort=high task" 0
PLAIN_OUT="$(AGENT_MODEL_DEFAULT="$MC_DEF" AGENT_MODEL_FLASH="$MC_FLASH" \
  AGENT_EFFORT_DEFAULT="$MC_EFF" ANTHROPIC_BASE_URL="$MC_BASE" \
  bash "$MC" --comment-file "$TMP/comment.txt" --trivial 0 2>/dev/null)"
if [ "$MC_RC" -eq 0 ] && [ "$MC_OUT" = "$PLAIN_OUT" ]; then
  pass "claude resolution identical with and without --harness"
else
  fail "claude resolution identical with and without --harness" "rc=$MC_RC"
fi
if [ "$(env_value AGENT_RESOLVED_HARNESS)" = "claude" ]; then
  pass "resolver reports the resolved harness"
else
  fail "resolver reports the resolved harness" "got '$(env_value AGENT_RESOLVED_HARNESS)'"
fi

# codex: override > repo var > CLI default.
MC_CODEX="gpt-5.1-codex"; MC_EFF=""
run_mc codex "-" 0
if [ "$(env_value AGENT_RESOLVED_MODEL)" = "gpt-5.1-codex" ]; then
  pass "codex repo var AGENT_MODEL_CODEX applies"
else
  fail "codex repo var AGENT_MODEL_CODEX applies" "got '$(env_value AGENT_RESOLVED_MODEL)'"
fi
run_mc codex "@codex model=gpt-5.2 task" 0
if [ "$(env_value AGENT_RESOLVED_MODEL)" = "gpt-5.2" ] \
  && printf '%s' "$(env_value AGENT_RUN_SUMMARY)" | grep -Fq "(comment-override)"; then
  pass "codex comment model override wins"
else
  fail "codex comment model override wins" "out=$MC_OUT"
fi
MC_CODEX=""
run_mc codex "-" 0
if [ -z "$(env_value AGENT_RESOLVED_MODEL)" ] \
  && printf '%s' "$(env_value AGENT_RUN_SUMMARY)" | grep -Fq "(cli-default)"; then
  pass "codex without var or override uses the CLI default"
else
  fail "codex without var or override uses the CLI default" "out=$MC_OUT"
fi
run_mc codex "@codex model=sonnet task" 0
if [ "$MC_RC" -ne 0 ] && [ -z "$MC_OUT" ] \
  && printf '%s' "$MC_ERR" | grep -Fq "claude-specific"; then
  pass "claude model alias rejected for codex with actionable message"
else
  fail "claude model alias rejected for codex" "rc=$MC_RC err=$MC_ERR"
fi
MC_CODEX="gpt-5.1-codex"
run_mc codex "@codex effort=high task" 0
if [ "$(env_value AGENT_RESOLVED_EFFORT)" = "high" ]; then
  pass "codex accepts supported effort override"
else
  fail "codex accepts supported effort override" "out=$MC_OUT"
fi
for bad in xhigh max minimal; do
  run_mc codex "@codex effort=$bad task" 0
  if [ "$MC_RC" -ne 0 ] && [ -z "$MC_OUT" ] \
    && printf '%s' "$MC_ERR" | grep -Fq "low, medium, high"; then
    pass "codex rejects unsupported effort $bad listing valid values"
  else
    fail "codex rejects unsupported effort $bad" "rc=$MC_RC err=$MC_ERR"
  fi
done

# gemini: model resolution, effort unsupported.
MC_GEMINI="gemini-2.5-pro"
run_mc gemini "@gemini model=gemini-3-pro task" 0
if [ "$(env_value AGENT_RESOLVED_MODEL)" = "gemini-3-pro" ]; then
  pass "gemini comment model override applies"
else
  fail "gemini comment model override applies" "out=$MC_OUT"
fi
run_mc gemini "-" 0
if [ "$(env_value AGENT_RESOLVED_MODEL)" = "gemini-2.5-pro" ]; then
  pass "gemini repo var AGENT_MODEL_GEMINI applies"
else
  fail "gemini repo var AGENT_MODEL_GEMINI applies" "out=$MC_OUT"
fi
run_mc gemini "@gemini effort=high task" 0
if [ "$MC_RC" -ne 0 ] && [ -z "$MC_OUT" ] \
  && printf '%s' "$MC_ERR" | grep -Fq "does not support effort"; then
  pass "gemini rejects effort override with actionable message"
else
  fail "gemini rejects effort override" "rc=$MC_RC err=$MC_ERR"
fi
MC_EFF="high"
run_mc gemini "-" 0
if [ "$MC_RC" -eq 0 ] && [ -z "$(env_value AGENT_RESOLVED_EFFORT)" ] \
  && printf '%s' "$MC_ERR" | grep -Fq "ignored"; then
  pass "gemini notes ignored repo effort default instead of failing"
else
  fail "gemini notes ignored repo effort default" "rc=$MC_RC err=$MC_ERR"
fi
MC_EFF=""

# opencode: provider-agnostic model ids.
MC_OPENCODE="anthropic/glm-4.7"
run_mc opencode "-" 0
if [ "$(env_value AGENT_RESOLVED_MODEL)" = "anthropic/glm-4.7" ]; then
  pass "opencode repo var AGENT_MODEL_OPENCODE applies"
else
  fail "opencode repo var AGENT_MODEL_OPENCODE applies" "out=$MC_OUT"
fi
run_mc opencode "@opencode effort=low task" 0
if [ "$MC_RC" -ne 0 ] && [ -z "$MC_OUT" ]; then
  pass "opencode rejects effort override"
else
  fail "opencode rejects effort override" "rc=$MC_RC out=$MC_OUT"
fi

# unknown harness is a caller error.
MC_OUT="$(HARNESS=vagrant bash "$MC" --harness vagrant 2>"$TMP/mc.err")"; MC_RC=$?
MC_ERR="$(cat "$TMP/mc.err")"
if [ "$MC_RC" -ne 0 ] && printf '%s' "$MC_ERR" | grep -Fq "vagrant"; then
  pass "unknown harness rejected listing supported values"
else
  fail "unknown harness rejected" "rc=$MC_RC err=$MC_ERR"
fi

# ===========================================================================
# scripts/agent.sh: harness routes, credentials, CLI preflight (AC2, AC4)
# ===========================================================================
echo "== launcher: routes and preflight"

STUB="$TMP/stub"
mkdir -p "$STUB"
make_stub() { # make_stub <name>
  cat >"$STUB/$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$STUB/argv.log"
exit 0
EOF
  chmod +x "$STUB/$1"
}

argv_log() { cat "$STUB/argv.log"; }
argv_has() { grep -Fq -- "$1" "$STUB/argv.log"; }

run_agent_env() { # run_agent_env <harness> <model> <effort> <prompt>
  : >"$STUB/argv.log"
  AGENT_OUT=$(env PATH="$STUB:$PATH" \
    ANTHROPIC_AUTH_TOKEN=dummy ANTHROPIC_API_KEY=dummy CODEX_API_KEY=dummy \
    OPENAI_API_KEY=dummy GEMINI_API_KEY=dummy GOOGLE_API_KEY=dummy \
    AGENT="$1" AGENT_RESOLVED_MODEL="$2" AGENT_RESOLVED_EFFORT="$3" \
    bash "$LAUNCHER" "$4" 2>"$TMP/agent.err")
  AGENT_RC=$?
}

make_stub claude; make_stub codex; make_stub gemini; make_stub opencode

run_agent_env claude "opus-plan" "high" "fix issue 23"
if [ "$AGENT_RC" -eq 0 ] && argv_has -- "--permission-mode acceptEdits" \
  && argv_has -- "--model opus-plan" && argv_has -- "--effort high" \
  && argv_has -- "--max-turns 50" && argv_has -- "-p"; then
  pass "claude route: prompt, permissions, model and effort flags"
else
  fail "claude route flags" "rc=$AGENT_RC argv=$(argv_log)"
fi

run_agent_env codex "gpt-5.1-codex" "high" "fix issue 23"
if [ "$AGENT_RC" -eq 0 ] && argv_has -- "exec" && argv_has -- "--ephemeral" \
  && argv_has -- "--sandbox workspace-write" && argv_has -- "--model gpt-5.1-codex" \
  && argv_has -- "model_reasoning_effort=high"; then
  pass "codex route: exec, ephemeral, sandbox, model, reasoning effort"
else
  fail "codex route flags" "rc=$AGENT_RC argv=$(argv_log)"
fi

run_agent_env gemini "gemini-2.5-pro" "" "fix issue 23"
if [ "$AGENT_RC" -eq 0 ] && argv_has -- "--approval-mode=yolo" \
  && argv_has -- "--skip-trust" && argv_has -- "-p" \
  && argv_has -- "--model gemini-2.5-pro" \
  && ! grep -Eq '(^| )--yolo( |$)' "$STUB/argv.log"; then
  pass "gemini route: supported flags, no deprecated --yolo"
else
  fail "gemini route flags" "rc=$AGENT_RC argv=$(argv_log)"
fi

run_agent_env opencode "anthropic/glm-4.7" "" "fix issue 23"
if [ "$AGENT_RC" -eq 0 ] && argv_has -- "run" && argv_has -- "--auto" \
  && argv_has -- "--model anthropic/glm-4.7"; then
  pass "opencode route: run, auto-approve, provider/model id"
else
  fail "opencode route flags" "rc=$AGENT_RC argv=$(argv_log)"
fi

run_agent_env claude "" "" "fix issue 23"
if [ "$AGENT_RC" -eq 0 ] && ! grep -Fq -- "--model" "$STUB/argv.log"; then
  pass "empty resolved model omits the model flag (CLI default)"
else
  fail "empty resolved model omits the model flag" "argv=$(argv_log)"
fi

# missing credentials: fail fast, name the env vars, never print values
: >"$STUB/argv.log"
AGENT_OUT=$(env -u CODEX_API_KEY -u OPENAI_API_KEY PATH="$STUB:$PATH" \
  AGENT=codex bash "$LAUNCHER" "fix issue 23" 2>"$TMP/agent.err")
MISSING_RC=$?
AGENT_ERR="$(cat "$TMP/agent.err")"
if [ "$MISSING_RC" -ne 0 ] && [ ! -s "$STUB/argv.log" ] \
  && printf '%s' "$AGENT_ERR" | grep -Fq "CODEX_API_KEY" \
  && printf '%s' "$AGENT_ERR" | grep -Fq "OPENAI_API_KEY"; then
  pass "missing codex credentials fail fast naming the env vars"
else
  fail "missing codex credentials fail fast" "rc=$MISSING_RC err=$AGENT_ERR"
fi

SENTINEL="sk-sentinel-never-print-23"
: >"$STUB/argv.log"
AGENT_OUT=$(env PATH="$STUB:$PATH" CODEX_API_KEY="$SENTINEL" \
  AGENT=codex bash "$LAUNCHER" --check 2>"$TMP/agent.err")
CHECK_RC=$?
AGENT_ERR="$(cat "$TMP/agent.err")"
if printf '%s\n%s' "$AGENT_OUT" "$AGENT_ERR" | grep -Fq "$SENTINEL"; then
  fail "credential values never appear in launcher output"
else
  pass "credential values never appear in launcher output"
fi

# --check verifies CLI + credentials without executing the harness
if [ "$CHECK_RC" -eq 0 ] && [ ! -s "$STUB/argv.log" ]; then
  pass "--check verifies readiness without running the CLI"
else
  fail "--check verifies readiness without running the CLI" "rc=$CHECK_RC"
fi

# missing CLI: actionable message pointing at integrations + bootstrap.
# Hermetic PATH (only the utilities agent.sh needs plus a claude stub) so
# an ambient codex installation can never satisfy the lookup.
ONLY_CLAUDE="$TMP/only-claude"
mkdir -p "$ONLY_CLAUDE"
cp "$STUB/claude" "$ONLY_CLAUDE/claude"
for t in printenv bash; do
  p="$(command -v "$t")" && ln -s "$p" "$ONLY_CLAUDE/$t"
done
AGENT_OUT=$(env PATH="$ONLY_CLAUDE" CODEX_API_KEY=dummy \
  AGENT=codex bash "$LAUNCHER" "fix issue 23" 2>"$TMP/agent.err")
NOCLI_RC=$?
AGENT_ERR="$(cat "$TMP/agent.err")"
if [ "$NOCLI_RC" -eq 2 ] && printf '%s' "$AGENT_ERR" | grep -Fq "not found in PATH" \
  && printf '%s' "$AGENT_ERR" | grep -Fq "integrations" \
  && printf '%s' "$AGENT_ERR" | grep -Fq "bootstrap-env.sh"; then
  pass "missing harness CLI fails with install hint"
else
  fail "missing harness CLI fails with install hint" "rc=$NOCLI_RC err=$AGENT_ERR"
fi

AGENT_OUT=$(env PATH="$STUB:$PATH" CODEX_API_KEY=dummy \
  AGENT=vagrant bash "$LAUNCHER" "fix issue 23" 2>"$TMP/agent.err")
UNKNOWN_RC=$?
AGENT_ERR="$(cat "$TMP/agent.err")"
if [ "$UNKNOWN_RC" -eq 1 ] && printf '%s' "$AGENT_ERR" | grep -Fq "claude codex gemini opencode"; then
  pass "unknown harness rejected listing supported values"
else
  fail "unknown harness rejected" "rc=$UNKNOWN_RC err=$AGENT_ERR"
fi

AGENT_OUT=$(env PATH="$STUB:$PATH" CODEX_API_KEY=dummy \
  AGENT=codex bash "$LAUNCHER" 2>"$TMP/agent.err")
NOPROMPT_RC=$?
if [ "$NOPROMPT_RC" -ne 0 ]; then
  pass "missing prompt is a usage error"
else
  fail "missing prompt is a usage error" "rc=0"
fi

# ===========================================================================
# pinned tooling: project.json, preflight, bootstrap (AC2)
# ===========================================================================
echo "== pinned tooling"

for key in claude_code codex_cli gemini_cli opencode_cli; do
  pin="$(sed -n "s/.*\"$key\": \"\([^\"]*\)\".*/\1/p" "$PROJECT" | sed -n 1p)"
  if printf '%s' "$pin" | grep -Eq '^[0-9]+(\.[0-9]+)+$'; then
    pass "agent_tooling.$key is an exact pinned version ($pin)"
  else
    fail "agent_tooling.$key is an exact pinned version" "got '$pin'"
  fi
done

COPY="$TMP/copy"
mkdir -p "$COPY"
cp -R "$REPO_ROOT/." "$COPY/" 2>/dev/null
rm -rf "$COPY/.git" "$COPY/.agent/runs" "$COPY/.agent-work"

copy_cfg_arr() { # copy_cfg_arr <copy-dir> <key> <json-array>
  sed -i.tmp "s/\"$2\": \[[^]]*\]/\"$2\": [$3]/" "$1/.agent/project.json" && rm -f "$1/.agent/project.json.tmp"
}

( cd "$COPY" && bash scripts/agent-preflight.sh verify-project ) >/dev/null 2>&1
if [ $? -eq 0 ]; then
  pass "verify-project accepts the default claude-only configuration"
else
  fail "verify-project accepts the default claude-only configuration"
fi

copy_cfg_arr "$COPY" integrations '"claude", "codex"'
( cd "$COPY" && bash scripts/agent-preflight.sh verify-project ) >"$TMP/pf.out" 2>&1
if [ $? -eq 0 ]; then
  pass "verify-project accepts enabled codex integration with its pin"
else
  fail "verify-project accepts enabled codex integration" "$(cat "$TMP/pf.out")"
fi

CODEX_PIN="$(sed -n 's/.*"codex_cli": "\([^"]*\)".*/\1/p' "$REPO_ROOT/.agent/project.json" | sed -n 1p)"
sed -i.tmp "/\"codex_cli\":/d" "$COPY/.agent/project.json" && rm -f "$COPY/.agent/project.json.tmp"
( cd "$COPY" && bash scripts/agent-preflight.sh verify-project ) >"$TMP/pf.out" 2>&1
if [ $? -ne 0 ] && grep -Fq "codex_cli" "$TMP/pf.out"; then
  pass "enabled integration without a pin is rejected"
else
  fail "enabled integration without a pin is rejected" "$(cat "$TMP/pf.out")"
fi

# bootstrap installs exactly the pinned packages for enabled integrations
MOCKBIN="$TMP/mockbin"
MOCKLOG="$TMP/mock.log"
mkdir -p "$MOCKBIN"
cat >"$MOCKBIN/node" <<'EOF'
#!/usr/bin/env bash
set -u
[ "${1:-}" = "--version" ] || exit 0
echo "v20.9.0"
EOF
cat >"$MOCKBIN/npm" <<EOF
#!/usr/bin/env bash
set -u
printf 'npm %s\n' "\$*" >> "$MOCKLOG"
exit 0
EOF
cat >"$MOCKBIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
[ "${1:-} ${2:-}" = "auth status" ] && exit 0
exit 0
EOF
for b in claude codex; do
  cat >"$MOCKBIN/$b" <<EOF
#!/usr/bin/env bash
printf '%s run\n' "\$0" >> "$MOCKLOG"
exit 0
EOF
  chmod +x "$MOCKBIN/$b"
done
chmod +x "$MOCKBIN/node" "$MOCKBIN/npm" "$MOCKBIN/gh"
: >"$MOCKLOG"
COPY2="$TMP/copy-boot"
mkdir -p "$COPY2"
cp -R "$REPO_ROOT/." "$COPY2/" 2>/dev/null
rm -rf "$COPY2/.git" "$COPY2/.agent/runs" "$COPY2/.agent-work"
copy_cfg_arr "$COPY2" integrations '"claude", "codex"'
# deterministic core utilities only after the mock dir, so an ambient
# harness CLI (e.g. a real codex on a dev machine) can never satisfy the
# integration presence check
( cd "$COPY2" && env PATH="$MOCKBIN:/usr/bin:/bin" ANTHROPIC_AUTH_TOKEN=dummy \
    bash scripts/bootstrap-env.sh ) >"$TMP/boot.out" 2>&1
BOOT_RC=$?
CLAUDE_PIN="$(sed -n 's/.*"claude_code": "\([^"]*\)".*/\1/p' "$REPO_ROOT/.agent/project.json" | sed -n 1p)"
if [ "$BOOT_RC" -eq 0 ] \
  && grep -Fq "install -g @anthropic-ai/claude-code@$CLAUDE_PIN" "$MOCKLOG" \
  && grep -Fq "install -g @openai/codex@$CODEX_PIN" "$MOCKLOG"; then
  pass "bootstrap installs the pinned CLI for every enabled integration"
else
  fail "bootstrap installs the pinned CLI for every enabled integration" \
    "rc=$BOOT_RC log=$(cat "$MOCKLOG")"
fi

mv "$MOCKBIN/codex" "$TMP/codex.hidden"
( cd "$COPY2" && env PATH="$MOCKBIN:/usr/bin:/bin" ANTHROPIC_AUTH_TOKEN=dummy \
    bash scripts/bootstrap-env.sh ) >"$TMP/boot.out" 2>&1
if [ $? -ne 0 ] && grep -Fq "integration 'codex' missing from PATH" "$TMP/boot.out"; then
  pass "missing enabled integration CLI fails fast after bootstrap"
else
  fail "missing enabled integration CLI fails fast" "$(cat "$TMP/boot.out")"
fi
mv "$TMP/codex.hidden" "$MOCKBIN/codex"

# ===========================================================================
# gemini role-specific context (AC2)
# ===========================================================================
echo "== gemini context"

if [ -f "$REPO_ROOT/.gemini/settings.json" ] \
  && grep -Fq "AGENTS.md" "$REPO_ROOT/.gemini/settings.json" \
  && grep -Fq "context" "$REPO_ROOT/.gemini/settings.json"; then
  pass "gemini settings load AGENTS.md as role context"
else
  fail "gemini settings load AGENTS.md as role context" ".gemini/settings.json missing or incomplete"
fi

# ===========================================================================
# workflow wiring (AC3)
# ===========================================================================
echo "== workflow wiring"

for m in claude codex gemini opencode; do
  grep -Fq "'@$m'" "$CLAUDE_YML" \
    && pass "claude.yml job condition recognizes @$m" \
    || fail "claude.yml job condition recognizes @$m" "not found"
done

grep -Fq 'AGENT_HARNESSES: ${{ vars.AGENT_HARNESSES }}' "$CLAUDE_YML" \
  && pass "claude.yml maps AGENT_HARNESSES from the vars context" \
  || fail "claude.yml maps AGENT_HARNESSES from the vars context" "no env mapping"

grep -Fq 'steps.filter.outputs.harness' "$CLAUDE_YML" \
  && pass "dispatch consumes the filter's harness verdict" \
  || fail "dispatch consumes the filter's harness verdict" "not referenced"

grep -Fq -- '--harness' "$CLAUDE_YML" \
  && pass "model resolution is harness-aware in the workflow" \
  || fail "model resolution is harness-aware in the workflow" "no --harness flag"

grep -Fq 'AGENT_MODEL_CODEX: ${{ vars.AGENT_MODEL_CODEX }}' "$CLAUDE_YML" \
  && pass "claude.yml maps AGENT_MODEL_CODEX from vars" \
  || fail "claude.yml maps AGENT_MODEL_CODEX from vars" "no env mapping"

grep -Fq 'agent.sh --check' "$CLAUDE_YML" \
  && pass "workflow preflights the harness CLI and credentials" \
  || fail "workflow preflights the harness CLI and credentials" "no agent.sh --check"

grep -Fq 'CODEX_API_KEY: ${{ secrets.CODEX_API_KEY }}' "$CLAUDE_YML" \
  && pass "codex credential secret is mapped for dispatch" \
  || fail "codex credential secret is mapped for dispatch" "no env mapping"

grep -Fq 'GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}' "$CLAUDE_YML" \
  && pass "gemini credential secret is mapped for dispatch" \
  || fail "gemini credential secret is mapped for dispatch" "no env mapping"

grep -Fq 'AGENT="$HARNESS"' "$CLAUDE_YML" \
  && pass "non-claude harnesses dispatch through scripts/agent.sh" \
  || fail "non-claude harnesses dispatch through scripts/agent.sh" "no launcher route"

grep -Fq 'agent-task.sh run' "$CLAUDE_YML" \
  && pass "every harness reuses the shared agent-task.sh pipeline" \
  || fail "every harness reuses the shared agent-task.sh pipeline" "not wired"

grep -Fq 'agent-claim.sh acquire' "$CLAUDE_YML" \
  && pass "PR-comment path keeps the shared claim protocol" \
  || fail "PR-comment path keeps the shared claim protocol" "not wired"

# ===========================================================================
# documentation (AC6)
# ===========================================================================
echo "== documentation"

grep -Fq "AGENT_HARNESSES" "$README" \
  && pass "README documents AGENT_HARNESSES" \
  || fail "README documents AGENT_HARNESSES" "not mentioned"

for v in AGENT_MODEL_CODEX AGENT_MODEL_GEMINI AGENT_MODEL_OPENCODE; do
  grep -Fq "$v" "$README" \
    && pass "README documents $v" \
    || fail "README documents $v" "not mentioned"
done

grep -Fq "codex-action" "$README" \
  && pass "README notes the official Codex integration conflict" \
  || fail "README notes the official Codex integration conflict" "not mentioned"

grep -Fq "AGENT_HARNESSES" "$INSTALL" \
  && pass "INSTALL shows how to enable harness mentions" \
  || fail "INSTALL shows how to enable harness mentions" "not mentioned"

grep -Fq -- "--approval-mode=yolo" "$HARNESSES_DOC" \
  && pass "HARNESSES.md documents the supported gemini flag" \
  || fail "HARNESSES_DOC gemini flag" "no --approval-mode=yolo"

if grep -Eq 'gemini --yolo' "$HARNESSES_DOC"; then
  fail "HARNESSES.md drops the deprecated gemini --yolo invocation" "still present"
else
  pass "HARNESSES.md drops the deprecated gemini --yolo invocation"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
