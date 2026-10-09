#!/usr/bin/env bash
# Structured review verdicts and merge authorization (issue #19; supersedes
# the issue #28/#13 comment-lookup contract).
#
# The independent reviewer's report is DATA, not authority. The trusted
# workflow steps distill it into a verdict artifact ("write") bound to the
# PR number, the exact reviewed head SHA, the identity of the run that
# performed the review, and a digest of the CI gate evidence. The merge
# decider ("merge") re-validates all of that against live PR state right
# before merging. PR comments -- including the reviewer bots' (issue #13:
# github-actions[bot] / the AGENT_REVIEWER_BOT_LOGIN repo variable,
# whichever identity scripts/app-auth.sh resolved; the deployment's login
# resolves via scripts/reviewer-identity.sh, failing closed to
# github-actions[bot] alone when unset or malformed) -- are display-only
# and never authorize a merge.
#
# Artifact (JSON, schema 1): schema, pr, verdict, head_sha, run_id,
# run_attempt, created_at, report, evidence{dir, gate_digest}.
# gate_digest = sha256 over gate.json + "\n" + test-first.json in the
# evidence dir, binding the verdict to the exact deterministic results.
#
# "merge" fails closed on: missing/malformed/inconsistent artifacts, a
# non-Actions context (implementation agents never merge), a run-id mismatch
# (artifacts cannot cross workflow runs), a live head different from the
# reviewed head (stale approval), and missing/substituted/rejected gate
# evidence. Only a fully valid APPROVE merges (squash only, matching the
# required linear history enforced by setup.sh); REQUEST_CHANGES requeues
# the PR via the agent-failed label.
#
# Usage:
#   scripts/review-verdict.sh write <pr> --reviewer-output FILE --head-sha SHA
#                                  [--artifact FILE] [--evidence-dir DIR]
#   scripts/review-verdict.sh merge <pr> [--artifact FILE] [--evidence-dir DIR]
#                                  [--gate-target DIR]
#
#   --evidence-dir defaults to $CI_GATE_EVIDENCE; --artifact defaults to
#   <evidence-dir>/review-verdict.json; --gate-target forwards the reviewed
#   working tree to ci-gate.sh check.
#
# Exit codes:
#   0 ok (a valid REQUEST_CHANGES label counts as ok)
#   2 usage / invalid arguments
#   3 verdict artifact missing, malformed or inconsistent
#   4 reviewer output carries no exactly-once usable VERDICT line (write)
#   5 merge command failed
#   6 CI gate evidence missing, tampered with or rejected
#   7 PR head unresolvable or changed since the review
#   8 run identity mismatch (no run context / different run)
#   9 mutation requested outside GitHub Actions
set -u

die() { # die <exit-code> <message...>
  echo "review-verdict: $2" >&2
  exit "$1"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  review-verdict.sh write <pr> --reviewer-output FILE --head-sha SHA
                        [--artifact FILE] [--evidence-dir DIR]
  review-verdict.sh merge <pr> [--artifact FILE] [--evidence-dir DIR]
                        [--gate-target DIR]
EOF
  exit 2
}

[ $# -ge 2 ] || usage
MODE="$1"
PR="$2"
case "$MODE" in
  write | merge) ;;
  *) usage ;;
esac
shift 2
case "$PR" in '' | *[!0-9]*) usage ;; esac

REVIEWER_OUT=""
HEAD_SHA_IN=""
ARTIFACT=""
EVIDENCE="${CI_GATE_EVIDENCE:-}"
GATE_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reviewer-output) [ $# -ge 2 ] || usage; REVIEWER_OUT="$2"; shift 2 ;;
    --head-sha) [ $# -ge 2 ] || usage; HEAD_SHA_IN="$2"; shift 2 ;;
    --artifact) [ $# -ge 2 ] || usage; ARTIFACT="$2"; shift 2 ;;
    --evidence-dir) [ $# -ge 2 ] || usage; EVIDENCE="$2"; shift 2 ;;
    --gate-target) [ $# -ge 2 ] || usage; GATE_TARGET="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [ "$MODE" = write ]; then
  { [ -n "$REVIEWER_OUT" ] && [ -n "$HEAD_SHA_IN" ]; } || usage
else
  { [ -z "$REVIEWER_OUT" ] && [ -z "$HEAD_SHA_IN" ]; } || usage
fi

is_sha() { # is_sha <value> -- exactly 40 lowercase hex characters
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
    ????????????????????????????????????????) return 0 ;;
    *) return 1 ;;
  esac
}

gate_digest() { # gate_digest <evidence-dir> -- sha256 over the gate evidence
  { cat "$1/gate.json" && printf '\n' && cat "$1/test-first.json"; } 2>/dev/null |
    openssl dgst -sha256 -r | sed 's/[^0-9a-f].*//'
}

resolve_evidence() {
  [ -n "$EVIDENCE" ] ||
    die 6 "no CI gate evidence: set CI_GATE_EVIDENCE or pass --evidence-dir (issue #19: no evidence, no merge)"
  { [ -f "$EVIDENCE/gate.json" ] && [ -f "$EVIDENCE/test-first.json" ]; } ||
    die 6 "gate evidence incomplete under $EVIDENCE: need gate.json and test-first.json"
  DIGEST="$(gate_digest "$EVIDENCE")"
  [ -n "$DIGEST" ] || die 6 "cannot digest the gate evidence under $EVIDENCE"
}

# ------------------------------------------------------------- write mode ---
if [ "$MODE" = write ]; then
  [ -f "$REVIEWER_OUT" ] || die 4 "reviewer output not found: $REVIEWER_OUT"
  [ -s "$REVIEWER_OUT" ] || die 4 "reviewer output is empty: $REVIEWER_OUT"
  is_sha "$HEAD_SHA_IN" ||
    die 2 "--head-sha must be a 40-character lowercase hex SHA (got: $HEAD_SHA_IN)"

  RUN_ID="${GITHUB_RUN_ID:-}"
  [ -n "$RUN_ID" ] || die 8 "write requires GITHUB_RUN_ID (run identity binding)"

  # The verdict token counts in exactly two shapes, case-sensitive, and the
  # whole report must carry it exactly once (issue #62):
  #   1. a line STARTING with "VERDICT: APPROVE" or "VERDICT: REQUEST_CHANGES"
  #      (the prompt-pinned strict format; trailing prose is fine), anywhere;
  #   2. within the first 10 lines only, a markdown heading embedding the
  #      token after an em-dash separator, e.g. "## Independent audit —
  #      VERDICT: APPROVE" (PR #58's shape).
  # Everything else -- indented, quoted, lowercased or space-less look-alikes,
  # headings without the em-dash separator, headings past line 10 -- is prose.
  # Zero matches, more than one match (duplicates count even when they agree)
  # or two tokens on a single line are all ambiguous and fail closed (exit 4);
  # tolerance never widens into an ambiguity path to merging.
  VERDICT=""
  matches=0
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    tokens=0
    rest="$line"
    while :; do
      case "$rest" in
        *"VERDICT: "*) tokens=$((tokens + 1)); rest="${rest#*VERDICT: }" ;;
        *) break ;;
      esac
    done
    if [ "$tokens" -gt 1 ]; then
      die 4 "line $lineno of $REVIEWER_OUT carries $tokens VERDICT tokens; ambiguous, refusing to pick one"
    fi
    [ "$tokens" -eq 1 ] || continue
    v=""
    case "$line" in
      "VERDICT: APPROVE"*) v=APPROVE ;;
      "VERDICT: REQUEST_CHANGES"*) v=REQUEST_CHANGES ;;
    esac
    if [ -z "$v" ] && [ "$lineno" -le 10 ]; then
      case "$line" in
        \#*)
          case "$line" in
            *"— VERDICT: APPROVE"*) v=APPROVE ;;
            *"— VERDICT: REQUEST_CHANGES"*) v=REQUEST_CHANGES ;;
          esac
          ;;
      esac
    fi
    [ -n "$v" ] || continue
    VERDICT="$v"
    matches=$((matches + 1))
  done < "$REVIEWER_OUT"
  if [ "$matches" -ne 1 ]; then
    [ "$matches" -eq 0 ] ||
      die 4 "$matches VERDICT lines in $REVIEWER_OUT; exactly one is required, refusing to pick"
    die 4 "no usable VERDICT line in $REVIEWER_OUT: need exactly one line starting with 'VERDICT: APPROVE' or 'VERDICT: REQUEST_CHANGES' (a markdown heading embedding it after an em-dash within the first 10 lines also counts)"
  fi

  resolve_evidence

  [ -n "$ARTIFACT" ] || ARTIFACT="$EVIDENCE/review-verdict.json"
  node -e '
    const fs = require("fs");
    const artifact = {
      schema: 1,
      pr: Number(process.argv[2]),
      verdict: process.argv[3],
      head_sha: process.argv[4],
      run_id: process.argv[5],
      run_attempt: String(process.argv[6]),
      created_at: process.argv[7],
      report: fs.readFileSync(process.argv[1], "utf8"),
      evidence: { dir: process.argv[8], gate_digest: process.argv[9] },
    };
    fs.writeFileSync(process.argv[10], JSON.stringify(artifact, null, 2) + "\n");
  ' "$REVIEWER_OUT" "$PR" "$VERDICT" "$HEAD_SHA_IN" "$RUN_ID" \
    "${GITHUB_RUN_ATTEMPT:-1}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$EVIDENCE" "$DIGEST" "$ARTIFACT" ||
    die 3 "failed to write the verdict artifact to $ARTIFACT"
  echo "verdict artifact: $ARTIFACT (PR #$PR, $VERDICT, head $HEAD_SHA_IN, run $RUN_ID)"
  exit 0
fi

# ------------------------------------------------------------- merge mode ---
[ -n "$ARTIFACT" ] || {
  [ -n "$EVIDENCE" ] ||
    die 3 "no artifact: pass --artifact, or --evidence-dir to use <evidence>/review-verdict.json"
  ARTIFACT="$EVIDENCE/review-verdict.json"
}

FIELDS="$(node -e '
  const fs = require("fs");
  let a;
  try { a = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
  catch (e) { process.exit(1); }
  const schema = a && a.schema,
    pr = a && a.pr,
    verdict = a && a.verdict,
    head = a && a.head_sha,
    run = a && a.run_id,
    digest = a && a.evidence && a.evidence.gate_digest;
  if (schema !== 1) process.exit(1);
  if (typeof pr !== "number" || typeof verdict !== "string" ||
      typeof head !== "string" || typeof run !== "string" ||
      typeof digest !== "string") process.exit(1);
  process.stdout.write([pr, verdict, head, run, digest].join("\n") + "\n");
' "$ARTIFACT" 2>/dev/null)" ||
  die 3 "verdict artifact is missing or unreadable: $ARTIFACT"
[ -n "$FIELDS" ] || die 3 "verdict artifact is malformed JSON or fails schema 1: $ARTIFACT"

A_PR="$(printf '%s\n' "$FIELDS" | sed -n 1p)"
A_VERDICT="$(printf '%s\n' "$FIELDS" | sed -n 2p)"
A_HEAD="$(printf '%s\n' "$FIELDS" | sed -n 3p)"
A_RUN="$(printf '%s\n' "$FIELDS" | sed -n 4p)"
A_DIGEST="$(printf '%s\n' "$FIELDS" | sed -n 5p)"

[ "$A_PR" = "$PR" ] || die 3 "verdict artifact is for PR #$A_PR but was invoked for PR #$PR"
case "$A_VERDICT" in
  APPROVE | REQUEST_CHANGES) ;;
  *) die 3 "verdict artifact carries verdict '$A_VERDICT'; expected APPROVE or REQUEST_CHANGES" ;;
esac
is_sha "$A_HEAD" || die 3 "verdict artifact head_sha is malformed: $A_HEAD"

# Implementation agents run this script locally too; only the review workflow
# may mutate the PR (AC5: never merge independently).
[ "${GITHUB_ACTIONS:-}" = "true" ] ||
  die 9 "mutating PR #$PR is only allowed inside the GitHub Actions review workflow; implementation agents never merge"
[ -n "${GITHUB_RUN_ID:-}" ] || die 9 "GITHUB_RUN_ID is not set; refusing to mutate PR #$PR"
[ "$A_RUN" = "$GITHUB_RUN_ID" ] ||
  die 8 "verdict artifact is from run $A_RUN, this is run $GITHUB_RUN_ID; stale run evidence is not merge authorization"

REPO="${GITHUB_REPOSITORY:-}"
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) ||
    die 7 "cannot resolve the repository to fetch the live head of PR #$PR"
fi
LIVE_HEAD="$(gh api "repos/$REPO/pulls/$PR" 2>/dev/null | node -e '
  const chunks = [];
  process.stdin.on("data", (c) => chunks.push(c));
  process.stdin.on("end", () => {
    try {
      const pr = JSON.parse(chunks.join("") || "null");
      const sha = pr && pr.head && pr.head.sha;
      if (typeof sha !== "string" || !sha) process.exit(1);
      process.stdout.write(sha);
    } catch (e) { process.exit(1); }
  });
')" || true
[ -n "$LIVE_HEAD" ] || die 7 "cannot resolve the live head of PR #$PR; failing closed"
[ "$LIVE_HEAD" = "$A_HEAD" ] ||
  die 7 "PR #$PR head changed since the review (reviewed $A_HEAD, live $LIVE_HEAD); the approval is stale"

resolve_evidence
[ "$DIGEST" = "$A_DIGEST" ] ||
  die 6 "gate evidence under $EVIDENCE does not match the artifact digest; the evidence changed after the review"

GATE_SCRIPT="$(dirname "$0")/ci-gate.sh"
if [ -n "$GATE_TARGET" ]; then
  bash "$GATE_SCRIPT" check --evidence-dir "$EVIDENCE" --target-dir "$GATE_TARGET" ||
    die 6 "CI quality gate evidence rejected for PR #$PR (gate-target $GATE_TARGET); not merging"
else
  bash "$GATE_SCRIPT" check --evidence-dir "$EVIDENCE" ||
    die 6 "CI quality gate evidence rejected for PR #$PR; not merging"
fi

if [ "$A_VERDICT" = "APPROVE" ]; then
  # Squash, never a merge commit: setup.sh enforces required_linear_history
  # on deployed repos and would reject merge commits.
  if ! gh pr merge "$PR" --squash --delete-branch 2>/dev/null; then
    gh pr merge "$PR" --squash --delete-branch ||
      die 5 "merge of PR #$PR failed"
  fi
  echo "approved verdict verified for head $A_HEAD (run $A_RUN); merged"
else
  echo "review rejected PR #$PR (head $A_HEAD); labeled agent-failed"
  gh pr edit "$PR" --add-label agent-failed ||
    echo "review-verdict: warning: could not label PR #$PR agent-failed" >&2
fi
