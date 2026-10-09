#!/usr/bin/env bash
# Deterministic CI quality gate, independent of agent-generated review text.
#
# Reads the single source of truth (.agent/project.json) and runs the
# configured install/build/test/lint/typecheck commands, recording a
# machine-verifiable evidence artifact instead of trusting prose claims.
# For code changes it also verifies test-first (red -> green) evidence: some
# commit in the reviewed range must leave the configured test suite failing
# before HEAD turns it green -- an implementation-before-tests history is
# rejected, and so is a code change that ships without tests.
#
# Stable status-check contract (do not rename; setup.sh registers it as a
# required check when branch protection is available):
#   workflow "CI Gate" + job "quality-gate"  ->  "CI Gate / quality-gate"
# When branch protection is unavailable, the merge controller enforces the
# same gate: scripts/review-verdict.sh runs `ci-gate.sh check` (via
# CI_GATE_EVIDENCE) and refuses to merge on anything but accepted evidence.
#
# Usage:
#   scripts/ci-gate.sh run   [--evidence-dir DIR] [--base REF] [--target-dir DIR]
#   scripts/ci-gate.sh check [--evidence-dir DIR] [--target-dir DIR]
#
#   run    Execute every configured command (cwd is forced to the target dir,
#          default: the script's own repository root), capture each command's
#          output and exit code under DIR (default .ci-evidence), and evaluate
#          test-first evidence for the commit range BASE..HEAD. Exit 0 only
#          when every executed command succeeds and the evidence is complete.
#   check  Verify an existing evidence artifact without re-running commands:
#          every required check (test, plus install/build/lint/typecheck when
#          configured) needs a record with exit 0 and a non-empty log, and
#          the test-first evidence must be accepted. Used by the merge
#          controller before merging.
#
#   --target-dir DIR  Validate a different working tree (the reviewed PR
#          checkout) while keeping THIS script's revision as the trusted
#          policy source: the command set is always read from the
#          .agent/project.json next to this script (issue #19: PR-supplied
#          policy changes are review input, not authoritative control).
#
# Evidence layout (one JSON record per line, parsed with sed only):
#   gate.json        {"checks": [{"name", "command", "exit", "log"}, ...]}
#   test-first.json  {"status": "verified|no-code-change|failed|no-base", ...}
#   <name>.log       captured output of each executed command
#
# Exit codes: 0 = gate passed, 1 = gate failed, 2 = usage error.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
# Policy source: always the revision this script was checked out from, never
# the --target-dir tree under review (issue #19).
PROJECT_FILE="$REPO_ROOT/.agent/project.json"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/ci-gate.sh <mode> [options]
  run   [--evidence-dir DIR] [--base REF] [--target-dir DIR]  run the gate
  check [--evidence-dir DIR] [--target-dir DIR]               verify evidence
EOF
  exit 2
}

MODE="${1:-}"
case "$MODE" in
  run | check) ;;
  *) usage ;;
esac
shift

EVIDENCE="$REPO_ROOT/.ci-evidence"
BASE=""
TARGET="$REPO_ROOT"
while [ $# -gt 0 ]; do
  case "$1" in
    --evidence-dir)
      [ $# -ge 2 ] || usage
      EVIDENCE="$2"
      shift 2
      ;;
    --base)
      [ $# -ge 2 ] || usage
      BASE="$2"
      shift 2
      ;;
    --target-dir)
      [ $# -ge 2 ] || usage
      TARGET="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

# Resolve relative dirs against the invocation directory before any cd
# changes the meaning of relative paths.
case "$EVIDENCE" in
  /*) ;;
  *) EVIDENCE="$(pwd)/$EVIDENCE" ;;
esac
case "$TARGET" in
  /*) ;;
  *) TARGET="$(pwd)/$TARGET" ;;
esac

# --- minimal JSON access (same controlled format as bootstrap-env.sh) -------

project_section() { # project_section <section>
  sed -n "/^  \"$1\": {/,/^  }/p" "$PROJECT_FILE"
}

project_scalar() { # project_scalar <section> <key>
  printf '%s\n' "$1" | sed -n "s/^ *\"$2\": \"\(.*\)\",\{0,1\}\$/\1/p"
}

if [ ! -f "$PROJECT_FILE" ]; then
  echo "gate: FAIL missing project configuration .agent/project.json" >&2
  exit 1
fi

cmd_of() { # cmd_of <name> -- configured command, empty when not configured
  project_scalar "$(project_section commands)" "$1"
}

required_checks() { # required check names, one per line
  echo test
  for n in install build lint typecheck; do
    [ -n "$(cmd_of "$n")" ] && echo "$n"
  done
}

suite_exit_at() { # suite_exit_at <sha> -> exit code of the configured test command at that commit
  wt="$(mktemp -d "${TMPDIR:-/tmp}/ci-gate-wt.XXXXXX")"
  rmdir "$wt"
  if ! git -C "$TARGET" worktree add --detach "$wt" "$1" >/dev/null 2>&1; then
    printf 'worktree unavailable for %s\n' "$1" >> "$EVIDENCE/test-first.log"
    return 200
  fi
  cmd=""
  if [ -f "$wt/.agent/project.json" ]; then
    saved_project="$PROJECT_FILE"
    PROJECT_FILE="$wt/.agent/project.json"
    cmd="$(project_scalar "$(project_section commands)" test)"
    PROJECT_FILE="$saved_project"
  fi
  red=2
  if [ -n "$cmd" ]; then
    ( cd "$wt" && bash -c "$cmd" ) >> "$EVIDENCE/test-first.log" 2>&1
    red=$?
  else
    printf 'no test command configured at %s\n' "$1" >> "$EVIDENCE/test-first.log"
  fi
  git -C "$TARGET" worktree remove --force "$wt" >/dev/null 2>&1
  git -C "$TARGET" worktree prune >/dev/null 2>&1
  return "$red"
}

if [ "$MODE" = run ]; then
  # ------------------------------------------------------------- run mode ---
  cd "$TARGET" || { echo "gate: FAIL cannot enter $TARGET" >&2; exit 1; }
  mkdir -p "$EVIDENCE" \
    || { echo "gate: FAIL cannot create evidence dir $EVIDENCE" >&2; exit 1; }
  rm -f "$EVIDENCE/gate.json" "$EVIDENCE/test-first.json"
  rm -f "$EVIDENCE"/*.log

  overall=0
  if [ -z "$(cmd_of test)" ]; then
    echo "gate: FAIL test command not configured" >&2
    overall=1
  fi

  printf '{\n  "checks": [\n' > "$EVIDENCE/gate.json"
  first=1
  for name in install build test lint typecheck; do
    cmd="$(cmd_of "$name")"
    [ -n "$cmd" ] || continue
    printf 'gate: %s %s\n' "$name" "$cmd"
    bash -c "$cmd" > "$EVIDENCE/$name.log" 2>&1
    rc=$?
    if [ "$first" -eq 1 ]; then first=0; else printf ',\n' >> "$EVIDENCE/gate.json"; fi
    printf '    {"name": "%s", "command": "%s", "exit": %s, "log": "%s.log"}' \
      "$name" "$cmd" "$rc" "$name" >> "$EVIDENCE/gate.json"
    if [ "$rc" -ne 0 ]; then
      printf 'gate: FAIL %s exited %s\n' "$name" "$rc" >&2
      overall=1
    fi
  done
  printf '\n  ]\n}\n' >> "$EVIDENCE/gate.json"

  # ------------------------------------------------- test-first evaluation --
  HEAD_SHA="$(git -C "$TARGET" rev-parse HEAD 2>/dev/null)" || HEAD_SHA=""

  tf_write() { # tf_write <status> [extra fields: "key": "value", ...]
    st="$1"
    extra="${2:-}"
    if [ -n "$extra" ]; then
      printf '{"status": "%s", %s, "head": "%s"}\n' "$st" "$extra" "$HEAD_SHA" \
        > "$EVIDENCE/test-first.json"
    else
      printf '{"status": "%s", "head": "%s"}\n' "$st" "$HEAD_SHA" \
        > "$EVIDENCE/test-first.json"
    fi
    reason="$(printf '%s\n' "$extra" | sed -n 's/.*"reason": "\([^"]*\)".*/\1/p')"
    printf 'gate: test-first %s%s\n' "$st" "${reason:+ ($reason)}"
  }

  tf_ok=1
  if [ -z "$BASE" ]; then
    # No base ref: the command gate still ran, but the artifact is not
    # acceptable merge evidence (check rejects the no-base status).
    tf_write no-base
  elif ! fork="$(git -C "$TARGET" merge-base "$BASE" HEAD 2>/dev/null)"; then
    tf_write failed '"reason": "invalid-base"'
    tf_ok=0
  else
    base_sha="$(git -C "$TARGET" rev-parse "$BASE" 2>/dev/null || printf '%s' "$BASE")"
    code_changed=0
    tests_changed=0
    while IFS= read -r f; do
      case "$f" in
        tests/*) tests_changed=1 ;;
        # Documentation and agent-instruction content is not gated code.
        *.md|*.txt|*.png|*.jpg|docs/*|.specify/*|specs/*|.claude/*|.codex/*) ;;
        .gitignore|LICENSE|LICENSE.*) ;;
        *) code_changed=1 ;;
      esac
    done < <(git -C "$TARGET" diff --name-only "$fork" HEAD 2>/dev/null)

    if [ "$code_changed" -eq 0 ]; then
      tf_write no-code-change "\"base\": \"$base_sha\""
    elif [ "$tests_changed" -eq 0 ]; then
      tf_write failed "\"reason\": \"code-change-without-tests\", \"base\": \"$base_sha\""
      tf_ok=0
    else
      red_commit=""
      wt_error=0
      : > "$EVIDENCE/test-first.log"
      for sha in $(git -C "$TARGET" rev-list --reverse "$fork..HEAD" 2>/dev/null); do
        touched=0
        while IFS= read -r p; do
          case "$p" in tests/*) touched=1 ;; esac
        done < <(git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only -r --root "$sha")
        [ "$touched" -eq 1 ] || continue
        suite_exit_at "$sha"
        red_exit=$?
        if [ "$red_exit" -eq 200 ]; then
          wt_error=1
          break
        fi
        if [ "$red_exit" -ne 0 ]; then
          red_commit="$sha"
          break
        fi
      done
      if [ -n "$red_commit" ]; then
        tf_write verified \
          "\"base\": \"$base_sha\", \"red_commit\": \"$red_commit\", \"red_suite_exit\": $red_exit, \"log\": \"test-first.log\""
      elif [ "$wt_error" -eq 1 ]; then
        tf_write failed "\"reason\": \"worktree-unavailable\", \"base\": \"$base_sha\""
        tf_ok=0
      else
        tf_write failed "\"reason\": \"no-red-commit\", \"base\": \"$base_sha\""
        tf_ok=0
      fi
    fi
  fi
  [ "$tf_ok" -eq 1 ] || overall=1

  if [ "$overall" -eq 0 ]; then
    printf 'gate: passed (evidence: %s)\n' "$EVIDENCE"
    exit 0
  fi
  printf 'gate: failed\n' >&2
  exit 1
fi

# ----------------------------------------------------------- check mode ---
problems=0
gate_json="$EVIDENCE/gate.json"

fail_msg() {
  printf 'gate-check: FAIL %s\n' "$1" >&2
  problems=$((problems + 1))
}

if [ ! -f "$gate_json" ]; then
  echo "gate-check: FAIL missing evidence: gate.json" >&2
  exit 1
fi

while IFS= read -r n; do
  line="$(grep -F "\"name\": \"$n\"" "$gate_json" | tail -1)"
  if [ -z "$line" ]; then
    fail_msg "required check '$n' has no evidence record"
    continue
  fi
  status="$(printf '%s\n' "$line" | sed -n 's/.*"status": "\([^"]*\)".*/\1/p')"
  if [ -n "$status" ] && [ "$status" != ok ]; then
    fail_msg "required check '$n' $status"
    continue
  fi
  exit_code="$(printf '%s\n' "$line" | sed -n 's/.*"exit": \([0-9]\{1,\}\).*/\1/p')"
  if [ "$exit_code" != 0 ]; then
    fail_msg "required check '$n' exited ${exit_code:-<none>}"
    continue
  fi
  log="$(printf '%s\n' "$line" | sed -n 's/.*"log": "\([^"]*\)".*/\1/p')"
  if [ -z "$log" ] || [ ! -f "$EVIDENCE/$log" ]; then
    fail_msg "required check '$n' log ${log:-<none>} missing"
  fi
done < <(required_checks)

tf="$EVIDENCE/test-first.json"
if [ ! -f "$tf" ]; then
  fail_msg "missing evidence: test-first.json"
else
  st="$(sed -n 's/.*"status": "\([^"]*\)".*/\1/p' "$tf" | sed -n 1p)"
  case "$st" in
    verified)
      red="$(sed -n 's/.*"red_commit": "\([^"]*\)".*/\1/p' "$tf" | sed -n 1p)"
      if [ -z "$red" ] \
        || ! git -C "$TARGET" rev-parse --verify --quiet "$red^{commit}" >/dev/null 2>&1 \
        || ! git -C "$TARGET" merge-base --is-ancestor "$red" HEAD >/dev/null 2>&1; then
        fail_msg "test-first red_commit is not resolvable in this repository"
      fi
      ;;
    no-code-change) ;;
    *) fail_msg "test-first evidence '${st:-<none>}' not accepted" ;;
  esac
fi

if [ "$problems" -gt 0 ]; then
  printf 'gate-check: failed (%s problem(s))\n' "$problems" >&2
  exit 1
fi
printf 'gate-check: passed\n'
exit 0
