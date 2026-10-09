#!/usr/bin/env bash
# Recover a verdict comment posted before the reviewer session died (issue #73).
#
# PR #68's audit: the reviewer session published its complete, well-formed
# report as a PR comment, then exited non-zero anyway (API instability at
# session end). The wrapper's fail-closed branch discarded the verdict and the
# whole audit had to re-run. This script lets the pr-review wrapper honor a
# verdict that was already published. It scans the PR comments for reports
# that
#   - are authored by the allowlisted reviewer bot identity (exact match via
#     scripts/reviewer-identity.sh; the PR author or any other bot never
#     counts),
#   - were created at or after the review step's start epoch (--since: the
#     window of THIS run attempt; anything older is a stale run's noise), and
#   - carry a usable verdict under the SAME parser as scripts/review-verdict.sh
#     (its "parse" mode) -- this script never re-implements verdict parsing.
#
# Exactly one usable comment: its body is written verbatim to --out and the
# verdict is printed on stdout. Zero usable comments, an unusable comment
# list, or an ambiguous window (two or more usable comments, agreeing or not)
# exit non-zero and the caller keeps the existing fail-closed behavior.
#
# This is traceability, not authorization (issue #19): the comment body
# carries no authority. The caller feeds --out through review-verdict.sh
# write, which binds PR number, exact head SHA, run identity and gate
# evidence into the artifact; the merge decider re-validates all of it.
#
# Only the first 100 in-window comments are read (per_page cap, same
# limitation scripts/review-watchdog.sh accepts for its markers).
#
# Usage:
#   review-verdict-recover.sh <pr> --since EPOCH --out FILE [--repo OWNER/NAME]
#
# Exit codes:
#   0 recovered (verdict on stdout, report at --out)
#   1 not recoverable (no usable comment / comments unfetchable) -> fail closed
#   2 usage error
#   3 ambiguous window (two or more usable verdict comments) -> fail closed
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { # die <exit-code> <message...>
  echo "review-verdict-recover: $2" >&2
  exit "$1"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  review-verdict-recover.sh <pr> --since EPOCH --out FILE [--repo OWNER/NAME]
EOF
  exit 2
}

[ $# -ge 2 ] || usage
PR="$1"
case "$PR" in '' | *[!0-9]*) usage ;; esac
shift

SINCE=""
OUT=""
REPO="${GITHUB_REPOSITORY:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage; SINCE="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$SINCE" in '' | *[!0-9]*) usage ;; esac
[ -n "$OUT" ] || usage

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) ||
    die 1 "cannot resolve the repository to list the comments of PR #$PR"
fi

# Only allowlisted reviewer bot identities count (issue #36 resolver).
IDENTS="$(bash "$SELF_DIR/reviewer-identity.sh" list | paste -sd, -)" ||
  die 1 "cannot resolve the reviewer bot identity allowlist"
[ -n "$IDENTS" ] || IDENTS="github-actions[bot]"

# Copy every in-window comment by an allowlisted identity into a candidate
# directory; print the candidate count. Bodies never pass through shell
# interpolation: node writes them byte-exact. The server-side "since" filter
# is re-checked client-side against created_at (defense in depth).
CAND_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verdict-recover.XXXXXX")" ||
  die 1 "cannot create a candidate directory"
trap 'rm -rf "$CAND_DIR"' EXIT

SINCE_ISO="$(node -p 'new Date(Number(process.argv[1]) * 1000).toISOString()' "$SINCE")" ||
  die 1 "cannot convert --since $SINCE to an ISO timestamp"

COUNT="$(gh api "repos/$REPO/issues/$PR/comments?per_page=100&since=$SINCE_ISO" 2>/dev/null | node -e '
  const fs = require("fs");
  let comments;
  try { comments = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(1); }
  if (!Array.isArray(comments)) process.exit(1);
  const since = Number(process.argv[1]);
  const allowed = String(process.argv[2]).split(",").filter(Boolean);
  const dir = process.argv[3];
  let n = 0;
  for (const c of comments) {
    if (!c || typeof c.body !== "string" || !c.body.trim()) continue;
    const login = c.user && c.user.login;
    if (typeof login !== "string" || !allowed.some((a) => a === login)) continue;
    const t = Math.floor(Date.parse(c.created_at || "") / 1000) || 0;
    if (!t || t < since) continue;
    n += 1;
    fs.writeFileSync(dir + "/cand-" + String(n).padStart(4, "0") + ".md", c.body);
  }
  process.stdout.write(n + "\n");
' "$SINCE" "$IDENTS" "$CAND_DIR")" ||
  die 1 "cannot list the comments of PR #$PR; failing closed"

[ "$COUNT" -gt 0 ] ||
  die 1 "no reviewer report comment was posted in this window; failing closed"

# Parse each candidate with the one and only verdict parser. More than one
# usable verdict is ambiguous -> fail closed, exactly like duplicate verdict
# lines inside a single report.
USABLE=0
VERDICT=""
WINNER=""
for cand in "$CAND_DIR"/cand-*.md; do
  [ -f "$cand" ] || continue
  v="$(bash "$SELF_DIR/review-verdict.sh" parse "$PR" --reviewer-output "$cand" 2>/dev/null)" || {
    rc=$?
    [ "$rc" -eq 4 ] ||
      die 1 "verdict parsing failed unexpectedly on a candidate comment (exit $rc)"
    continue
  }
  USABLE=$((USABLE + 1))
  [ "$USABLE" -eq 1 ] ||
    die 3 "$USABLE usable verdict comments were posted in this window; ambiguous, refusing to pick one"
  VERDICT="$v"
  WINNER="$cand"
done

[ "$USABLE" -eq 1 ] ||
  die 1 "no usable verdict comment was posted in this window; failing closed"
cp "$WINNER" "$OUT" ||
  die 1 "cannot write the recovered report to $OUT"
printf '%s\n' "$VERDICT"
