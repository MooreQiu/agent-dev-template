#!/usr/bin/env bash
# Acceptance tests for issue #73: a completed, well-formed verdict must not be
# discarded just because the reviewer session later exited non-zero.
#
# PR #68's audit: the reviewer posted a full "VERDICT: APPROVE" report as a PR
# comment, then the session itself died (API instability). The wrapper's
# fail-closed branch stranded the verdict and the whole audit had to re-run.
#
# The contract added here has two halves:
#   1. scripts/review-verdict.sh grows a "parse" mode exposing the EXISTING
#      verdict parser (no second parser may exist) so other trusted steps can
#      ask "is this a usable verdict?": exit 0 = exactly one usable VERDICT
#      line (printed on stdout), exit 4 = unusable, exit 2 = usage.
#   2. scripts/review-verdict-recover.sh recovers a verdict comment posted
#      during the current review attempt: comments authored by the allowlisted
#      reviewer bot identity (scripts/reviewer-identity.sh), created at or
#      after the step's start, parsed with review-verdict.sh's parser. Exactly
#      one usable comment -> its body is written to --out and the verdict is
#      printed. Zero usable, an unusable fetch, or an ambiguous window (two or
#      more usable comments) -> non-zero: the caller keeps fail-closed.
# Authorization never comes from the comment: the workflow feeds the recovered
# body through review-verdict.sh write (binding PR/head SHA/run id/evidence)
# and the merge decider re-validates everything. With no recoverable verdict
# the workflow must keep the existing "⚠️ 审计运行异常" + exit 1 behavior.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/review-verdict.sh"
RECOVER="$REPO_ROOT/scripts/review-verdict-recover.sh"
WF="$REPO_ROOT/.github/workflows/pr-review.yml"
WATCHDOG="$REPO_ROOT/scripts/review-watchdog.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adt-test-recover73.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

GH_LOG="$TMP/gh.log"
MOCK_BIN="$TMP/bin"
mkdir -p "$MOCK_BIN"

# --- mocked gh: serves PR comments from a fixture -----------------------------
cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "gh $*" >> "$GH_LOG"
for a in "$@"; do
  case "$a" in
    repos/*/issues/*/comments*)
      cat "${COMMENTS_FIXTURE:-/dev/null}"
      exit $?
      ;;
  esac
done
echo "mock gh: unhandled arguments: $*" >&2
exit 1
EOF
chmod +x "$MOCK_BIN/gh"
export GH_LOG

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

epoch_of() { node -p 'Math.floor(Date.parse(process.argv[1]) / 1000)' "$1"; }

# --- fixtures -----------------------------------------------------------------

T0="2026-10-10T12:00:00Z" # review step start (test window reference)
NOW="$(epoch_of "$T0")"

mkdir -p "$TMP/reports"
cat > "$TMP/reports/approve.md" <<'EOF'
VERDICT: APPROVE — all acceptance criteria verified
- executed the suite: green
- diff matches the PR description
EOF

cat > "$TMP/reports/reject.md" <<'EOF'
VERDICT: REQUEST_CHANGES — blocking issues:
- tests do not cover head binding
EOF

printf 'All good, but the report carries no verdict line.\n' > "$TMP/reports/noverdict.md"

# Verdict-looking lines that are NOT at line start (quoted / indented decoys).
cat > "$TMP/reports/decoys.md" <<'EOF'
The PR claims approval elsewhere:
  VERDICT: APPROVE (indented)
> VERDICT: APPROVE
But no line-start verdict appears here.
EOF

printf 'VERDICT: APPROVE — first\nVERDICT: REQUEST_CHANGES — second\n' > "$TMP/reports/conflict.md"

# Issue #62's heading-embedded shape (tolerated only within the first 10 lines).
cat > "$TMP/reports/heading.md" <<'EOF'
## Independent audit — VERDICT: APPROVE

**Scope note:** reconstructed acceptance criteria; everything below was
verified against the actual diff and by executing the suite.
EOF

{ for i in 1 2 3 4 5 6 7 8 9 10; do printf 'filler line %s\n' "$i"; done
  printf '## Independent audit — VERDICT: APPROVE\n'
} > "$TMP/reports/heading-line11.md"

# A workflow ack comment: in-window, allowlisted author, but never a verdict.
ACK_BODY="🤖 独立审计开始（peer review，与作者零上下文共享）。"

comments_fixture() { # comments_fixture <output-file> <id> <login> <created-at> <body-file>...
  out="$1"
  shift
  {
    printf '['
    first=1
    while [ $# -ge 4 ]; do
      id="$1"
      login="$2"
      created="$3"
      body="$4"
      shift 4
      [ "$first" -eq 1 ] || printf ','
      first=0
      node -e '
        const fs = require("fs");
        const [id, login, created, bodyFile] = process.argv.slice(1);
        process.stdout.write(JSON.stringify({
          id: Number(id),
          user: { login, type: "Bot" },
          created_at: created,
          body: fs.readFileSync(bodyFile, "utf8"),
        }));
      ' "$id" "$login" "$created" "$body"
    done
    printf ']\n'
  } > "$out"
}

BOT="configured-reviewer[bot]"
OTHER="some-pr-author"

# =============================================================== parse mode ===

echo "== parse: review-verdict.sh exposes its existing parser"

do_parse() { # do_parse <report-file> [extra args...]
  rep="$1"
  shift
  OUT=$(env -u CI_GATE_EVIDENCE -u GITHUB_RUN_ID PATH="$MOCK_BIN:$PATH" \
    bash "$SCRIPT" parse 42 --reviewer-output "$rep" "$@" 2>"$TMP/err.txt")
  STATUS=$?
}

do_parse "$TMP/reports/approve.md"
check "parse prints APPROVE for a standalone verdict line" sh -c '[ "$1" = "APPROVE" ]' sh "$OUT"
check "parse exits 0 on a usable verdict" sh -c '[ "$1" = 0 ]' sh "$STATUS"

do_parse "$TMP/reports/reject.md"
check "parse prints REQUEST_CHANGES" sh -c '[ "$1" = "REQUEST_CHANGES" ]' sh "$OUT"
check "parse exits 0 on a REQUEST_CHANGES verdict" sh -c '[ "$1" = 0 ]' sh "$STATUS"

do_parse "$TMP/reports/heading.md"
check "parse accepts the issue #62 heading-embedded shape" \
  sh -c '[ "$1" = "APPROVE" ] && [ "$2" = 0 ]' sh "$OUT" "$STATUS"

do_parse "$TMP/reports/noverdict.md"
check "parse fails closed without a verdict line (exit 4)" sh -c '[ "$1" = 4 ]' sh "$STATUS"

do_parse "$TMP/reports/decoys.md"
check "parse rejects indented/quoted decoys (exit 4)" sh -c '[ "$1" = 4 ]' sh "$STATUS"

do_parse "$TMP/reports/conflict.md"
check "parse rejects conflicting verdict lines (exit 4)" sh -c '[ "$1" = 4 ]' sh "$STATUS"

do_parse "$TMP/reports/heading-line11.md"
check "parse rejects heading verdicts past line 10 (exit 4)" sh -c '[ "$1" = 4 ]' sh "$STATUS"

do_parse "$TMP/does-not-exist.md"
check "parse fails closed on a missing report (exit 4)" sh -c '[ "$1" = 4 ]' sh "$STATUS"

: > "$TMP/reports/empty.md"
do_parse "$TMP/reports/empty.md"
check "parse fails closed on an empty report (exit 4)" sh -c '[ "$1" = 4 ]' sh "$STATUS"

do_parse "$TMP/reports/approve.md" --head-sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
check "parse rejects verdict-write arguments (exit 2)" sh -c '[ "$1" = 2 ]' sh "$STATUS"

OUT=$(env -u CI_GATE_EVIDENCE PATH="$MOCK_BIN:$PATH" \
  bash "$SCRIPT" parse 42 2>"$TMP/err.txt")
STATUS=$?
check "parse requires --reviewer-output (exit 2)" sh -c '[ "$1" = 2 ]' sh "$STATUS"

OUT=$(env -u CI_GATE_EVIDENCE PATH="$MOCK_BIN:$PATH" \
  bash "$SCRIPT" parse 42 --reviewer-output "$TMP/reports/approve.md" --evidence-dir "$TMP" 2>"$TMP/err.txt")
STATUS=$?
check "parse rejects evidence arguments (exit 2)" sh -c '[ "$1" = 2 ]' sh "$STATUS"

# ============================================================ recover mode ====

echo "== recover: honor a verdict comment posted by a dying reviewer session"

do_recover() { # do_recover <since-epoch> <out-file> [extra env as VAR=val...]
  since="$1"
  out="$2"
  shift 2
  : > "$GH_LOG"
  rm -f "$out"
  OUT=$(env GITHUB_REPOSITORY=acme/fixture AGENT_REVIEWER_BOT_LOGIN="$BOT" \
    PATH="$MOCK_BIN:$PATH" "$@" \
    bash "$RECOVER" 42 --since "$since" --out "$out" 2>"$TMP/err.txt")
  STATUS=$?
}

# One allowlisted verdict comment inside the window, plus ack noise.
FX="$TMP/comments-one.json"
printf 'VERDICT: APPROVE — full report below\n1207 checks green, mutation-tested evidence.\n' > "$TMP/body-approve.txt"
comments_fixture "$FX" \
  101 "$BOT" "2026-10-10T11:59:59Z" "$TMP/reports/noverdict.md" \
  102 "$BOT" "$T0" "$TMP/body-approve.txt"

OUT_FILE="$TMP/recovered.md"
do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$FX"
check "recovers the single in-window verdict comment (exit 0)" sh -c '[ "$1" = 0 ]' sh "$STATUS"
check "prints the recovered verdict on stdout" sh -c '[ "$1" = "APPROVE" ]' sh "$OUT"
check "writes the comment body verbatim to --out" cmp -s "$TMP/body-approve.txt" "$OUT_FILE"

# REQUEST_CHANGES recovers too (a dying reviewer may reject as well).
FX_R="$TMP/comments-reject.json"
printf 'VERDICT: REQUEST_CHANGES — blocking issues listed below\n' > "$TMP/body-reject.txt"
comments_fixture "$FX_R" 103 "$BOT" "2026-10-10T12:05:00Z" "$TMP/body-reject.txt"
do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$FX_R"
check "recovers a REQUEST_CHANGES verdict comment" \
  sh -c '[ "$1" = 0 ] && [ "$2" = "REQUEST_CHANGES" ]' sh "$STATUS" "$OUT"

# The heading-embedded shape is equally usable from a comment.
FX_H="$TMP/comments-heading.json"
printf '## Independent audit — VERDICT: APPROVE\n\nverified by executing the suite.\n' > "$TMP/body-heading.txt"
comments_fixture "$FX_H" 104 "$BOT" "2026-10-10T12:05:00Z" "$TMP/body-heading.txt"
do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$FX_H"
check "recovers the issue #62 heading shape from a comment" \
  sh -c '[ "$1" = 0 ] && [ "$2" = "APPROVE" ]' sh "$STATUS" "$OUT"

# Comments by non-allowlisted authors never count, whatever they claim.
FX_FORGED="$TMP/comments-forged.json"
comments_fixture "$FX_FORGED" \
  105 "$OTHER" "2026-10-10T12:05:00Z" "$TMP/body-approve.txt" \
  106 "other-app[bot]" "2026-10-10T12:05:00Z" "$TMP/body-approve.txt"
do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$FX_FORGED"
check "a verdict comment by an unknown author is not recoverable" sh -c '[ "$1" = 1 ]' sh "$STATUS"
check "unrecoverable runs write no body to --out" test ! -s "$OUT_FILE"

# Comments older than the window are stale-run noise.
FX_STALE="$TMP/comments-stale.json"
comments_fixture "$FX_STALE" 107 "$BOT" "2026-10-10T11:59:59Z" "$TMP/body-approve.txt"
do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$FX_STALE"
check "a verdict comment from before the window is not recoverable" sh -c '[ "$1" = 1 ]' sh "$STATUS"

# Boundary: a comment created exactly at the window start counts.
FX_EDGE="$TMP/comments-edge.json"
comments_fixture "$FX_EDGE" 108 "$BOT" "$T0" "$TMP/body-approve.txt"
do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$FX_EDGE"
check "a comment created exactly at the window start counts" sh -c '[ "$1" = 0 ]' sh "$STATUS"

# In-window noise without verdicts recovers nothing.
printf '%s\n' "$ACK_BODY" > "$TMP/ack.txt"
FX_NOISY="$TMP/comments-noisy.json"
comments_fixture "$FX_NOISY" \
  109 "$BOT" "2026-10-10T12:00:10Z" "$TMP/ack.txt" \
  110 "$BOT" "2026-10-10T12:03:00Z" "$TMP/reports/noverdict.md" \
  111 "$BOT" "2026-10-10T12:04:00Z" "$TMP/reports/decoys.md"
do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$FX_NOISY"
check "ack comments and verdict-less/decoy comments recover nothing" sh -c '[ "$1" = 1 ]' sh "$STATUS"

# Ambiguity fails closed: two usable verdict comments, even agreeing ones.
FX_AMBIG="$TMP/comments-ambiguous.json"
comments_fixture "$FX_AMBIG" \
  112 "$BOT" "2026-10-10T12:01:00Z" "$TMP/body-approve.txt" \
  113 "$BOT" "2026-10-10T12:02:00Z" "$TMP/body-approve.txt"
do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$FX_AMBIG"
check "two usable verdict comments in the window fail closed" sh -c '[ "$1" = 3 ]' sh "$STATUS"
check "ambiguous windows write no body to --out" test ! -s "$OUT_FILE"

# Mixed ambiguity: one usable verdict plus one conflicted report stays usable.
FX_MIXED="$TMP/comments-mixed.json"
comments_fixture "$FX_MIXED" \
  114 "$BOT" "2026-10-10T12:01:00Z" "$TMP/reports/conflict.md" \
  115 "$BOT" "2026-10-10T12:02:00Z" "$TMP/body-approve.txt"
do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$FX_MIXED"
check "a conflicted verdict comment is not a second usable verdict" sh -c '[ "$1" = 0 ]' sh "$STATUS"

# Unusable fetches fail closed.
FX_BAD="$TMP/comments-bad.json"
printf 'not json at all\n' > "$FX_BAD"
do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$FX_BAD"
check "malformed comment payloads fail closed (exit 1)" sh -c '[ "$1" = 1 ]' sh "$STATUS"

do_recover "$NOW" "$OUT_FILE" COMMENTS_FIXTURE="$TMP/no-such-fixture.json"
check "an unfetchable comment list fails closed (exit 1)" sh -c '[ "$1" = 1 ]' sh "$STATUS"

# Usage discipline.
OUT=$(env GITHUB_REPOSITORY=acme/fixture PATH="$MOCK_BIN:$PATH" \
  bash "$RECOVER" not-a-number --since "$NOW" --out "$OUT_FILE" 2>"$TMP/err.txt")
check "non-numeric PR numbers are usage errors (exit 2)" sh -c '[ "$1" = 2 ]' sh "$?"
OUT=$(env GITHUB_REPOSITORY=acme/fixture PATH="$MOCK_BIN:$PATH" \
  bash "$RECOVER" 42 --out "$OUT_FILE" 2>"$TMP/err.txt")
check "--since is mandatory (exit 2)" sh -c '[ "$1" = 2 ]' sh "$?"
OUT=$(env GITHUB_REPOSITORY=acme/fixture PATH="$MOCK_BIN:$PATH" \
  bash "$RECOVER" 42 --since not-an-epoch --out "$OUT_FILE" 2>"$TMP/err.txt")
check "non-numeric --since is rejected" sh -c '[ "$1" = 2 ]' sh "$?"
OUT=$(env GITHUB_REPOSITORY=acme/fixture PATH="$MOCK_BIN:$PATH" \
  bash "$RECOVER" 42 --since "$NOW" 2>"$TMP/err.txt")
check "--out is mandatory (exit 2)" sh -c '[ "$1" = 2 ]' sh "$?"

# The recovery path must reuse the single verdict parser, never grow its own.
check "recover delegates parsing to review-verdict.sh parse" \
  sh -c 'grep -Fq "review-verdict.sh" "$1" && grep -q "parse" "$1"' sh "$RECOVER"
check "recover ships no second verdict scanner" \
  sh -c '! grep -Eq "VERDICT: (APPROVE|REQUEST_CHANGES)" "$1"' sh "$RECOVER"
check "recover trusts only the reviewer bot identity allowlist" \
  sh -c 'grep -Fq "reviewer-identity.sh" "$1"' sh "$RECOVER"

# ========================================================== workflow wiring ===

echo "== workflow wiring"

check "the reviewer step records its start time for the recovery window" \
  sh -c 'grep -Fq "date -u +%s" "$1"' sh "$WF"
check "the wrapper attempts verdict recovery on a non-zero reviewer exit" \
  sh -c 'grep -Fq "review-verdict-recover.sh" "$1"' sh "$WF"
check "fail-closed stays the default when nothing is recoverable" \
  sh -c 'grep -Fq "审计运行异常" "$1" && grep -B1 -A2 -F "审计运行异常" "$1" | grep -Fq "exit 1"' sh "$WF"
check "the verdict write step consumes the recovered report when recovered" \
  sh -c 'grep -Fq "steps.review.outputs.recovered" "$1" && grep -Fq "reviewer-verdict-recovered.md" "$1"' sh "$WF"
check "the recovered report is uploaded for the audit trail" \
  sh -c 'grep -Fq "reviewer-verdict-recovered.md" "$1"' sh "$WF"
check "the recovery script joins the protected merge-control paths" \
  sh -c 'grep -Fq "^scripts/review-verdict-recover\\.sh$" "$1"' sh "$WF"
check "the watchdog mirror of the control paths follows suit" \
  sh -c 'grep -Fq "review-verdict-recover" "$1"' sh "$WATCHDOG"
check "the reviewer step is addressable for step outputs" \
  sh -c 'grep -Fq "id: review" "$1"' sh "$WF"

# ========= issue #94: zero-exit sessions whose output lacks the verdict ======
#
# PR #86's audit (run 38021380044, attempt 2): the reviewer session exited 0
# after posting a complete, substantively positive report as a PR comment, but
# the mandatory VERDICT line was missing from BOTH the posted comment and the
# captured session stdout. The issue #73 recovery only engages on a non-zero
# exit, so the recorder took the unparsable stdout and failed the whole run
# (exit 4). The zero-exit branch must therefore engage the SAME recovery
# (same trust rules: allowlisted identity, in-window, single parser) whenever
# the parser rejects the session output, before the recorder can fail -- and
# keep failing closed with a precise alert when the window holds nothing
# usable. Prose never becomes a verdict on any of these paths.

echo "== issue #94: the zero-exit branch engages the same recovery first"

check "the zero-exit branch probes the session output with the single verdict parser" \
  sh -c 'grep -Fq "review-verdict.sh parse \"\$N\" --reviewer-output \"\$RUNNER_TEMP/reviewer-output.md\"" "$1"' sh "$WF"
check "the zero-exit branch attempts comment recovery when the parser rejects the output" \
  sh -c '[ "$(grep -cF "scripts/review-verdict-recover.sh \"\$N\"" "$1")" -ge 2 ]' sh "$WF"
check "both recovery branches feed the recovered report to the recorder" \
  sh -c '[ "$(grep -cF "echo \"recovered=true\" >> \"\$GITHUB_OUTPUT\"" "$1")" -ge 2 ]' sh "$WF"
check "the zero-exit recovery announces the honored verdict on the PR" \
  sh -c 'grep -Fq "其输出缺少可解析的 VERDICT 行" "$1"' sh "$WF"
check "an unrecoverable zero-exit window fails closed with a precise alert" \
  sh -c 'grep -Fq "都没有可解析的 VERDICT 行" "$1" && grep -B1 -A2 -F "都没有可解析的 VERDICT 行" "$1" | grep -Fq "exit 1"' sh "$WF"
check "the reviewer prompt pins the final reply to the verdict-bearing report" \
  sh -c 'grep -Fq "最终回复必须就是这份报告原文" "$1"' sh "$WF"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All tests passed"
