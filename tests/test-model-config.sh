#!/usr/bin/env bash
# Acceptance tests for issue #9: model and reasoning-effort configuration
# for @claude dispatch.
#
# Criteria covered:
#   - repository defaults: normal/trivial tier selection preserved when no
#     override is supplied (vars win over hardcoded fallback)
#   - comment override syntax "@claude model=opus effort=high <task>" with
#     strict precedence: comment > repository config > documented fallback
#   - alias resolution: sonnet/opus -> AGENT_MODEL_DEFAULT tier,
#     haiku -> AGENT_MODEL_FLASH tier; concrete ids pass through
#   - malformed/unsupported values rejected with an actionable message
#     (valid options listed), conflicting duplicates rejected
#   - shell-injection-like input never executes and never reaches the
#     emitted environment lines unvalidated (stdout stays empty on reject)
#   - report line names endpoint (no credentials), model, and requested
#     effort with their sources; distinguishes defaults and provider-
#     dependent (unknown) effort effectiveness
#   - workflow wiring: claude.yml resolves via scripts/model-config.sh,
#     gates dispatch on its verdict, applies --model/--effort, and the
#     acknowledgement carries the run summary
#   - documentation: README and INSTALL cover the vars, comment syntax,
#     and precedence
#
# Run: bash tests/test-model-config.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MC="$REPO_ROOT/scripts/model-config.sh"
CLAUDE_YML="$REPO_ROOT/.github/workflows/claude.yml"
README="$REPO_ROOT/README.md"
INSTALL="$REPO_ROOT/INSTALL.md"
SETUP="$REPO_ROOT/setup.sh"

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+ -- $2}"; failures=$((failures + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export ANTHROPIC_AUTH_TOKEN="secret-sentinel-do-not-print"

if [ ! -f "$MC" ]; then
  fail "scripts/model-config.sh exists" "file not found"
  echo "$failures test(s) failed"
  exit 1
fi

# Repository configuration under test (empty means unset/fallback).
MC_DEF=""
MC_FLASH=""
MC_EFF=""
MC_BASE=""

# run_mc <comment-text|-(empty)> <trivial 0|1>
# Sets MC_RC, MC_OUT (stdout: GITHUB_ENV lines), MC_ERR (stderr: report).
run_mc() {
  if [ "$1" = "-" ]; then
    : >"$TMP/comment.txt"
  else
    printf '%s\n' "$1" >"$TMP/comment.txt"
  fi
  MC_OUT="$(AGENT_MODEL_DEFAULT="$MC_DEF" AGENT_MODEL_FLASH="$MC_FLASH" \
    AGENT_EFFORT_DEFAULT="$MC_EFF" ANTHROPIC_BASE_URL="$MC_BASE" \
    bash "$MC" --comment-file "$TMP/comment.txt" --trivial "$2" 2>"$TMP/mc.err")"
  MC_RC=$?
  MC_ERR="$(cat "$TMP/mc.err")"
}

# env_value <NAME> -- first value of NAME= from MC_OUT
env_value() {
  printf '%s\n' "$MC_OUT" | sed -n "s/^$1=//p" | sed -n 1p
}

expect_rc0() {
  if [ "$MC_RC" -eq 0 ]; then pass "$1"; else fail "$1" "rc=$MC_RC err=$MC_ERR"; fi
}
expect_reject() { # <name> <needle-for-actionable-message>
  if [ "$MC_RC" -eq 0 ]; then
    fail "$1" "rc=0 (accepted) out=$MC_OUT"
  elif [ -z "$MC_OUT" ]; then
    if [ -z "$2" ] || printf '%s' "$MC_ERR" | grep -Fq "$2"; then
      pass "$1"
    else
      fail "$1" "error lacks actionable text '$2': $MC_ERR"
    fi
  else
    fail "$1" "rejected but stdout not empty (would pollute GITHUB_ENV): $MC_OUT"
  fi
}
expect_eq() { # <name> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2' want '$3'"; fi
}
expect_contains() { # <name> <haystack> <needle>
  if printf '%s' "$2" | grep -Fq -- "$3"; then pass "$1"; else fail "$1" "missing '$3' in: $2"; fi
}

# --- repository defaults (no override) ---

MC_DEF=""; MC_FLASH=""; MC_EFF=""; MC_BASE=""
run_mc "-" 0
expect_rc0 "no override, no repo vars: resolver succeeds"
expect_eq "fallback default model" "$(env_value AGENT_RESOLVED_MODEL)" "glm-5.3[1m]"
expect_eq "fallback alias mapping keeps sonnet=opus=default" "$(env_value ANTHROPIC_DEFAULT_SONNET_MODEL)" "glm-5.3[1m]"
expect_eq "fallback alias mapping opus" "$(env_value ANTHROPIC_DEFAULT_OPUS_MODEL)" "glm-5.3[1m]"
expect_eq "fallback alias mapping haiku=flash" "$(env_value ANTHROPIC_DEFAULT_HAIKU_MODEL)" "glm-5.3-flash[1m]"
expect_eq "effort defaults to CLI default (empty)" "$(env_value AGENT_RESOLVED_EFFORT)" ""
expect_contains "summary marks model source as fallback" "$(env_value AGENT_RUN_SUMMARY)" "model=glm-5.3[1m] (fallback)"

run_mc "-" 1
expect_rc0 "no override, trivial label: resolver succeeds"
expect_eq "trivial label selects fallback flash model" "$(env_value AGENT_RESOLVED_MODEL)" "glm-5.3-flash[1m]"

MC_DEF="repo-normal"; MC_FLASH="repo-flash"; MC_EFF=""; MC_BASE=""
run_mc "-" 0
expect_eq "repo var default model wins over fallback" "$(env_value AGENT_RESOLVED_MODEL)" "repo-normal"
expect_eq "repo var flash used for haiku alias tier" "$(env_value ANTHROPIC_DEFAULT_HAIKU_MODEL)" "repo-flash"
expect_contains "summary marks model source as repo-config" "$(env_value AGENT_RUN_SUMMARY)" "model=repo-normal (repo-config)"

run_mc "-" 1
expect_eq "trivial label selects repo flash tier" "$(env_value AGENT_RESOLVED_MODEL)" "repo-flash"

MC_DEF="repo-normal"; MC_FLASH="repo-flash"; MC_EFF="medium"; MC_BASE=""
run_mc "-" 0
expect_eq "repo var effort default applies" "$(env_value AGENT_RESOLVED_EFFORT)" "medium"
expect_contains "summary marks effort source as repo-config" "$(env_value AGENT_RUN_SUMMARY)" "effort=medium (repo-config)"

# --- comment overrides ---

MC_DEF="repo-normal"; MC_FLASH="repo-flash"; MC_EFF="medium"; MC_BASE=""
run_mc "@claude model=opus effort=high please fix the failing test" 0
expect_rc0 "valid model+effort override accepted"
expect_eq "model=opus resolves to repo default tier" "$(env_value AGENT_RESOLVED_MODEL)" "repo-normal"
expect_eq "effort=high override applies" "$(env_value AGENT_RESOLVED_EFFORT)" "high"
expect_contains "summary marks model source as comment-override" "$(env_value AGENT_RUN_SUMMARY)" "(comment-override)"

run_mc "@claude model=haiku quick task" 0
expect_eq "model=haiku resolves to repo flash tier" "$(env_value AGENT_RESOLVED_MODEL)" "repo-flash"

run_mc "@claude model=sonnet task" 1
expect_eq "model=sonnet override beats trivial label" "$(env_value AGENT_RESOLVED_MODEL)" "repo-normal"

run_mc "@claude model=glm-4.7 task" 0
expect_eq "concrete model id passes through" "$(env_value AGENT_RESOLVED_MODEL)" "glm-4.7"

run_mc "@claude effort=low task" 0
expect_eq "effort override beats repo effort default" "$(env_value AGENT_RESOLVED_EFFORT)" "low"

run_mc "@claude model=opus effort=high also model=opus again" 0
expect_rc0 "repeated identical override is not a conflict"

run_mc "please review the models=opus naming scheme" 0
expect_eq "models= (suffixed key) is not an override" "$(env_value AGENT_RESOLVED_MODEL)" "repo-normal"

run_mc "prefixmodel=opus task" 0
expect_eq "prefixmodel= (prefixed key) is not an override" "$(env_value AGENT_RESOLVED_MODEL)" "repo-normal"

# --- invalid comment input ---

MC_DEF="repo-normal"; MC_FLASH="repo-flash"; MC_EFF=""; MC_BASE=""
run_mc "@claude model=rm -rf / task" 0
expect_rc0 "space-separated shell words never merge into the model value"
expect_eq "only the single model= token is taken as the value" "$(env_value AGENT_RESOLVED_MODEL)" "rm"

run_mc "@claude model=opus;touch\${IFS}$TMP/pwned task" 0
expect_reject "semicolon injection payload is rejected" "sonnet"
if [ -e "$TMP/pwned" ]; then
  fail "injection payload did not execute" "$TMP/pwned exists"
else
  pass "injection payload did not execute"
fi

run_mc '@claude model=$(touch '"$TMP"'/pwned2) task' 0
expect_reject "command-substitution payload is rejected" "sonnet"
if [ -e "$TMP/pwned2" ]; then
  fail "command-substitution payload did not execute" "$TMP/pwned2 exists"
else
  pass "command-substitution payload did not execute"
fi

run_mc '@claude model=`touch '"$TMP"'/pwned3` task' 0
expect_reject "backtick payload is rejected" "sonnet"

# The reject message is echoed into a markdown code fence in a workflow
# comment: the raw (pre-validation) token must never carry backticks or
# excessive length, or attacker text can break out of the fence.
run_mc '@claude model=x```<b>not-markdown</b> task' 0
expect_reject "fence-breaking backtick payload is rejected" "sonnet"
if printf '%s' "$MC_ERR" | grep -q '`'; then
  fail "reject message cannot break out of its markdown fence" "raw backtick echoed: $MC_ERR"
else
  pass "reject message cannot break out of its markdown fence"
fi

run_mc '@claude model=```x model=```y task' 0
expect_reject "conflicting duplicate with fence-breaking values is rejected" "model"
if printf '%s' "$MC_ERR" | grep -q '`'; then
  fail "duplicate-conflict message cannot break out of its markdown fence" "raw backtick echoed: $MC_ERR"
else
  pass "duplicate-conflict message cannot break out of its markdown fence"
fi

run_mc '@claude effort=```high task' 0
expect_reject "fence-breaking effort payload is rejected" "low, medium, high, xhigh, max"
if printf '%s' "$MC_ERR" | grep -q '`'; then
  fail "effort reject message cannot break out of its markdown fence" "raw backtick echoed: $MC_ERR"
else
  pass "effort reject message cannot break out of its markdown fence"
fi

LONG_TOKEN="$(printf 'a%.0s' $(seq 1 200))"
run_mc "@claude model=$LONG_TOKEN task" 0
expect_reject "overlong model token is rejected" "sonnet"
if printf '%s' "$MC_ERR" | grep -q 'a\{60\}'; then
  fail "reject message truncates untrusted tokens" "long raw value echoed: $MC_ERR"
else
  pass "reject message truncates untrusted tokens"
fi

run_mc '@claude model="quoted model" task' 0
expect_reject "quoted value with spaces is rejected" "sonnet"

run_mc "@claude model= task" 0
expect_reject "empty model value is rejected" "sonnet"

run_mc "@claude effort=turbo task" 0
expect_reject "unsupported effort is rejected listing valid values" "low, medium, high, xhigh, max"

run_mc "@claude effort= task" 0
expect_reject "empty effort value is rejected" "low, medium, high, xhigh, max"

run_mc "@claude model=opus model=haiku task" 0
expect_reject "conflicting duplicate model override is rejected" "model"

run_mc "@claude effort=high effort=low task" 0
expect_reject "conflicting duplicate effort override is rejected" "effort"

# --- invalid repository configuration ---

MC_DEF="repo-normal"; MC_FLASH="repo-flash"; MC_EFF="bogus"; MC_BASE=""
run_mc "-" 0
if [ "$MC_RC" -ne 0 ] && printf '%s' "$MC_ERR" | grep -Fq "AGENT_EFFORT_DEFAULT"; then
  pass "invalid repo effort var fails with actionable message"
else
  fail "invalid repo effort var fails with actionable message" "rc=$MC_RC err=$MC_ERR"
fi

# --- report line: endpoint, model, effort, sources, no credentials ---

MC_DEF="repo-normal"; MC_FLASH="repo-flash"; MC_EFF=""; MC_BASE="https://open.bigmodel.cn/api/anthropic"
run_mc "@claude effort=high task" 0
expect_rc0 "third-party endpoint run resolves"
expect_contains "report names the provider endpoint" "$MC_ERR" "endpoint=https://open.bigmodel.cn/api/anthropic"
expect_contains "report flags provider-dependent effort effectiveness" "$MC_ERR" "provider-dependent"
expect_contains "ack summary includes model and effort" "$(env_value AGENT_RUN_SUMMARY)" "effort=high"
if printf '%s\n' "$MC_OUT$MC_ERR" | grep -Fq "secret-sentinel"; then
  fail "credentials never appear in output" "token sentinel leaked"
else
  pass "credentials never appear in output"
fi

MC_DEF=""; MC_FLASH=""; MC_EFF=""; MC_BASE=""
run_mc "@claude effort=high task" 0
expect_contains "default endpoint reported when unset" "$MC_ERR" "api.anthropic.com"

MC_DEF="repo-normal"; MC_FLASH="repo-flash"; MC_EFF=""; MC_BASE=""
run_mc "-" 0
expect_contains "unset effort is distinguished from a requested one" "$MC_ERR" "effort=(cli-default)"

# emitted env lines carry only validated, injection-safe values
MC_DEF=""; MC_FLASH=""; MC_EFF=""; MC_BASE=""
run_mc "@claude model=ok-model.4:ver/2[1m] task" 0
expect_rc0 "allowlisted charset model accepted"
v_model="$(env_value AGENT_RESOLVED_MODEL)"
v_eff="$(env_value AGENT_RESOLVED_EFFORT)"
leak=""
for ch in ';' '`' '$' '(' ')' '"' "'" ' '; do
  case "$v_model$v_eff" in
    *"$ch"*) leak="$leak[$ch]" ;;
  esac
done
if [ -n "$leak" ]; then
  fail "resolved values contain no shell metacharacters" "leaked:$leak"
else
  pass "resolved values contain no shell metacharacters"
fi

# --- structural safety ---

if grep -n "eval " "$MC" >/dev/null 2>&1; then
  fail "resolver never evals comment text" "eval found in scripts/model-config.sh"
else
  pass "resolver never evals comment text"
fi

# --- workflow wiring ---

grep -Fq "scripts/model-config.sh" "$CLAUDE_YML" \
  && pass "claude.yml resolves model/effort via scripts/model-config.sh" \
  || fail "claude.yml resolves model/effort via scripts/model-config.sh" "no reference found"

grep -Fq "steps.model.outputs.status == 'ok'" "$CLAUDE_YML" \
  && pass "claude.yml gates dispatch on the resolver verdict" \
  || fail "claude.yml gates dispatch on the resolver verdict" "no gate found"

grep -Fq 'AGENT_MODEL_DEFAULT: ${{ vars.AGENT_MODEL_DEFAULT }}' "$CLAUDE_YML" \
  && pass "claude.yml maps AGENT_MODEL_DEFAULT from vars context" \
  || fail "claude.yml maps AGENT_MODEL_DEFAULT from vars context" "no env mapping"

grep -Fq 'AGENT_MODEL_FLASH: ${{ vars.AGENT_MODEL_FLASH }}' "$CLAUDE_YML" \
  && pass "claude.yml maps AGENT_MODEL_FLASH from vars context" \
  || fail "claude.yml maps AGENT_MODEL_FLASH from vars context" "no env mapping"

grep -Fq 'AGENT_EFFORT_DEFAULT: ${{ vars.AGENT_EFFORT_DEFAULT }}' "$CLAUDE_YML" \
  && pass "claude.yml maps AGENT_EFFORT_DEFAULT from vars context" \
  || fail "claude.yml maps AGENT_EFFORT_DEFAULT from vars context" "no env mapping"

grep -Fq 'MODEL_ARGS=(--model "$AGENT_RESOLVED_MODEL")' "$CLAUDE_YML" \
  && pass "dispatch passes the resolved model to the claude CLI" \
  || fail "dispatch passes the resolved model to the claude CLI" "no --model wiring"

grep -Fq 'AGENT_RESOLVED_EFFORT' "$CLAUDE_YML" \
  && pass "dispatch applies the resolved effort when set" \
  || fail "dispatch applies the resolved effort when set" "no --effort wiring"

grep -Fq 'AGENT_RUN_SUMMARY' "$CLAUDE_YML" \
  && pass "acknowledgement comments carry the run summary" \
  || fail "acknowledgement comments carry the run summary" "summary not referenced"

# --- documentation ---

grep -Fq "AGENT_EFFORT_DEFAULT" "$README" \
  && pass "README documents AGENT_EFFORT_DEFAULT" \
  || fail "README documents AGENT_EFFORT_DEFAULT" "not mentioned"

grep -Eq 'model=(sonnet|opus|haiku)' "$README" \
  && pass "README documents the comment override syntax" \
  || fail "README documents the comment override syntax" "no model= syntax"

grep -Eq "优先级|precedence" "$README" \
  && pass "README documents override precedence" \
  || fail "README documents override precedence" "no precedence section"

grep -Fq "AGENT_EFFORT_DEFAULT" "$INSTALL" \
  && pass "INSTALL documents AGENT_EFFORT_DEFAULT" \
  || fail "INSTALL documents AGENT_EFFORT_DEFAULT" "not mentioned"

grep -Fq "gh variable set AGENT_EFFORT_DEFAULT" "$INSTALL" \
  && pass "INSTALL shows how to configure the effort var" \
  || fail "INSTALL shows how to configure the effort var" "no example"

grep -Eq "provider|供应商" "$README" \
  && pass "docs note provider-dependent effort effectiveness" \
  || fail "docs note provider-dependent effort effectiveness" "no limitation note"

grep -Fq "AGENT_EFFORT_DEFAULT" "$SETUP" \
  && pass "setup.sh supports the optional effort var" \
  || fail "setup.sh supports the optional effort var" "not referenced"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
