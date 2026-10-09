#!/usr/bin/env bash
# Watchdog for silently stranded reviews (issue #56).
#
# The independent audit in pr-review.yml is an LLM session that can die before
# it posts any verdict: a workflow-file parse error fails the run before any
# job even starts (PR #38's shape, conclusion=startup_failure), and an
# infrastructure error kills the reviewer step mid-flight. The run goes red,
# but nothing watches the run list -- the PR silently strands until a human
# asks. This script closes that gap WITHOUT touching the merge control path:
# it is a scanner over live PR/run state with exactly two bounded actions
# (an alert comment, and one rate-limited close+reopen re-trigger).
#
# Detection (first match wins; one classification per open agent/* PR):
#   no_run          the pr-review event never fired a run at all (event lost,
#                   workflow never triggered), past a grace window that keeps
#                   freshly opened PRs out of the blast radius
#   stuck           the latest pr-review run is still queued/in_progress
#                   beyond the expected window
#   run_failed      the latest pr-review run concluded failure / timed_out /
#                   startup_failure -- i.e. it failed BEFORE a verdict could
#                   be posted (startup_failure is the workflow-file-error
#                   shape PR #38 hit)
#   repair_stalled  the PR is labeled agent-failed but its head commit has
#                   not moved within the stall window (branch-level commit
#                   time, NOT the repo-wide pushed_at): the issue #20 repair
#                   loop is not running
#   (anything else is healthy -> a strict no-op)
#
# Actions:
#   - one alert comment per PR+mode per cooldown window. The alert carries
#     the PR number, run id/url, failure mode and a suggested next action,
#     plus a machine marker (<!-- review-watchdog:mode=... -->). Cooldown
#     state counts ONLY marker comments authored by the allowlisted reviewer
#     bot identity (scripts/reviewer-identity.sh): a PR author cannot forge
#     or silence watchdog state by commenting the marker themselves.
#   - close+reopen re-trigger, ONLY for no_run, ONLY when the PR touches no
#     merge-control path (the same patterns pr-review.yml protects, issue
#     #19: control-path PRs are handled by a human), ONLY after the alert
#     comment that carries its receipt marker actually posted, and at most
#     once per PR per cooldown window (marker
#     <!-- review-watchdog:action=retrigger -->).
#   - findings never fail the sweep: scan exits 0 when it completes, non-zero
#     only when it cannot scan at all.
#
# Usage:
#   scripts/review-watchdog.sh scan [--repo OWNER/NAME] [--now EPOCH]
#       [--alert-cooldown-hours N] [--retrigger-cooldown-hours N]
#       [--stuck-minutes N] [--no-run-grace-minutes N] [--stall-minutes N]
#
# Every threshold has an env default (WATCHDOG_* with the long-option name);
# the flags exist for tests and one-off operator runs.
#
# Exit codes: 0 scan completed (findings are not failures), 1 could not scan,
# 2 usage error.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_PATH=".github/workflows/pr-review.yml"
# Same merge-control paths pr-review.yml guards (issue #19).
CONTROL_PATH_RE='^\.github/workflows/pr-review\.yml$|^scripts/ci-gate\.sh$|^scripts/app-auth\.sh$|^scripts/review-verdict\.sh$|^scripts/review-verdict-recover\.sh$'
ALERT_MARKER='<!-- review-watchdog:mode='
RETRIGGER_MARKER='<!-- review-watchdog:action=retrigger'

usage() {
  cat >&2 <<'EOF'
Usage:
  review-watchdog.sh scan [--repo OWNER/NAME] [--now EPOCH]
                          [--alert-cooldown-hours N]
                          [--retrigger-cooldown-hours N]
                          [--stuck-minutes N] [--no-run-grace-minutes N]
                          [--stall-minutes N]
EOF
  exit 2
}

die() { printf 'review-watchdog: ERROR %s\n' "$*" >&2; exit 1; }
warn() { printf 'review-watchdog: WARN %s\n' "$*" >&2; }

REPO="${GITHUB_REPOSITORY:-}"
NOW=""
ALERT_COOLDOWN_H="${WATCHDOG_ALERT_COOLDOWN_HOURS:-24}"
RETRIGGER_COOLDOWN_H="${WATCHDOG_RETRIGGER_COOLDOWN_HOURS:-24}"
STUCK_MIN="${WATCHDOG_STUCK_MINUTES:-60}"
NO_RUN_GRACE_MIN="${WATCHDOG_NO_RUN_GRACE_MINUTES:-30}"
STALL_MIN="${WATCHDOG_STALL_MINUTES:-360}"

[ $# -ge 1 ] || usage
MODE="$1"
shift
[ "$MODE" = "scan" ] || usage
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --now) [ $# -ge 2 ] || usage; NOW="$2"; shift 2 ;;
    --alert-cooldown-hours) [ $# -ge 2 ] || usage; ALERT_COOLDOWN_H="$2"; shift 2 ;;
    --retrigger-cooldown-hours) [ $# -ge 2 ] || usage; RETRIGGER_COOLDOWN_H="$2"; shift 2 ;;
    --stuck-minutes) [ $# -ge 2 ] || usage; STUCK_MIN="$2"; shift 2 ;;
    --no-run-grace-minutes) [ $# -ge 2 ] || usage; NO_RUN_GRACE_MIN="$2"; shift 2 ;;
    --stall-minutes) [ $# -ge 2 ] || usage; STALL_MIN="$2"; shift 2 ;;
    *) usage ;;
  esac
done

for knob in "NOW:$NOW" "ALERT_COOLDOWN_H:$ALERT_COOLDOWN_H" \
  "RETRIGGER_COOLDOWN_H:$RETRIGGER_COOLDOWN_H" "STUCK_MIN:$STUCK_MIN" \
  "NO_RUN_GRACE_MIN:$NO_RUN_GRACE_MIN" "STALL_MIN:$STALL_MIN"; do
  name="${knob%%:*}"
  value="${knob#*:}"
  case "$value" in
    '' | *[!0-9]*) die "$name must be a non-negative integer (got: $value)" ;;
  esac
done

[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" ||
  die "cannot resolve the repository; set GITHUB_REPOSITORY or pass --repo"

# Cooldown state is only trusted from the allowlisted reviewer bot identity
# (issue #36 resolver): PR-authored markers are untrusted noise.
IDENTS="$(bash "$SELF_DIR/reviewer-identity.sh" list | paste -sd, -)"
[ -n "$IDENTS" ] || IDENTS="github-actions[bot]"

prs_rows() { # open PRs as TSV: number, head branch, created, head sha, agent-failed
  gh api "repos/$REPO/pulls?state=open&per_page=100" 2>/dev/null | node -e '
    const fs = require("fs");
    let list;
    try { list = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(1); }
    if (!Array.isArray(list)) process.exit(1);
    for (const p of list) {
      if (!p || typeof p.number !== "number") continue;
      const branch = p.head && p.head.ref;
      if (typeof branch !== "string") continue;
      const created = Math.floor(Date.parse(p.created_at || "") / 1000) || 0;
      const sha = p.head && typeof p.head.sha === "string" ? p.head.sha : "";
      const labels = Array.isArray(p.labels) ? p.labels : [];
      const rejected = labels.some((l) => l && l.name === "agent-failed") ? 1 : 0;
      process.stdout.write([p.number, branch, created, sha, rejected].join("\t") + "\n");
    }
  '
}

# Branch movement is measured on the PR head commit itself: the pulls list has
# no per-branch time, and head.repo.pushed_at is the repository-wide last push
# (refreshed by a push to ANY branch), which never goes stale in an active repo.
head_epoch() { # head_epoch <sha> -- commit time of a head commit; fails if unusable
  gh api "repos/$REPO/commits/$1" 2>/dev/null | node -e '
    const fs = require("fs");
    let c;
    try { c = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(1); }
    const cm = c && c.commit;
    const date = (cm && cm.committer && cm.committer.date) || (cm && cm.author && cm.author.date);
    const epoch = Math.floor(Date.parse(date || "") / 1000);
    if (!epoch) process.exit(1);
    process.stdout.write(epoch + "\n");
  '
}

latest_run() { # latest_run <branch> -- newest pr-review run as TSV
  # $1 is interpolated unencoded (GitHub branch names with "&" would need
  # URL-encoding); the head_branch equality filter below neutralizes injection.
  gh api "repos/$REPO/actions/runs?branch=$1&per_page=100" 2>/dev/null | node -e '
    const fs = require("fs");
    let data;
    try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(1); }
    const runs = data && Array.isArray(data.workflow_runs) ? data.workflow_runs : [];
    const mine = runs
      .filter((r) => r && r.head_branch === process.argv[1] && r.path === process.argv[2])
      .sort((a, b) => (Date.parse(b.created_at) || 0) - (Date.parse(a.created_at) || 0));
    const r = mine[0];
    if (!r) process.exit(3);
    const started = Math.floor(Date.parse(r.run_started_at || r.created_at || "") / 1000) || 0;
    process.stdout.write(
      [r.id, r.status || "", r.conclusion || "", r.html_url || "", started].join("\t") + "\n"
    );
  ' "$1" "$WORKFLOW_PATH"
}

marker_epoch() { # marker_epoch <pr> <marker> -- newest bot-authored marker time (0 = none)
  # Only the first 100 comments are read; older markers beyond that are
  # invisible (worst case: one duplicate alert on very long-lived PRs).
  gh api "repos/$REPO/issues/$1/comments?per_page=100" 2>/dev/null | node -e '
    const fs = require("fs");
    let comments;
    try { comments = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(1); }
    const allowed = process.argv[2].split(",").filter(Boolean);
    let best = 0;
    for (const c of Array.isArray(comments) ? comments : []) {
      if (!c || typeof c.body !== "string" || !c.body.includes(process.argv[1])) continue;
      const login = c.user && c.user.login;
      if (!allowed.some((a) => a === login)) continue;
      const t = Math.floor(Date.parse(c.created_at || "") / 1000) || 0;
      if (t > best) best = t;
    }
    process.stdout.write(best + "\n");
  ' "$2" "$IDENTS"
}

control_hits() { # control_hits <pr> -- merge-control filenames touched by the PR
  gh api "repos/$REPO/pulls/$1/files?per_page=100" 2>/dev/null | node -e '
    const fs = require("fs");
    let files;
    try { files = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(1); }
    const re = new RegExp(process.argv[1]);
    const names = (Array.isArray(files) ? files : [])
      .map((f) => f && f.filename)
      .filter((n) => typeof n === "string");
    process.stdout.write(names.filter((n) => re.test(n)).join("\n") + "\n");
  ' "$CONTROL_PATH_RE"
}

ROWS="$(prs_rows)" || die "cannot list the open PRs of $REPO"

printf '%s\n' "$ROWS" | while IFS="$(printf '\t')" read -r NUM BRANCH CREATED HEAD_SHA REJECTED; do
  [ -n "$NUM" ] || continue
  case "$BRANCH" in
    agent/*) ;;
    *) continue ;;
  esac

  # --- classify (first match wins) ------------------------------------------
  MODE=""
  RUN_ID=""
  RUN_STATUS=""
  RUN_LINE="Review run: none (no pr-review run ever started)"
  RUN_JSON="$(latest_run "$BRANCH")"
  RUN_RC=$?
  if [ "$RUN_RC" -eq 0 ]; then
    RUN_ID="$(printf '%s\n' "$RUN_JSON" | sed -n 1p | cut -f1)"
    RUN_STATUS="$(printf '%s\n' "$RUN_JSON" | sed -n 1p | cut -f2)"
    RUN_CONCL="$(printf '%s\n' "$RUN_JSON" | sed -n 1p | cut -f3)"
    RUN_URL="$(printf '%s\n' "$RUN_JSON" | sed -n 1p | cut -f4)"
    RUN_STARTED="$(printf '%s\n' "$RUN_JSON" | sed -n 1p | cut -f5)"
    RUN_LINE="Review run: [$RUN_ID]($RUN_URL)"
    case "$RUN_STATUS" in
      queued | in_progress)
        if [ "$RUN_STARTED" -le "$((NOW - STUCK_MIN * 60))" ]; then
          MODE="stuck"
        fi
        ;;
      *)
        case "$RUN_CONCL" in
          failure | timed_out | startup_failure)
            MODE="run_failed"
            ;;
          *)
            if [ "$REJECTED" = "1" ]; then
              BRANCH_EPOCH="$(head_epoch "$HEAD_SHA")" ||
                { warn "cannot read the head commit time of branch $BRANCH; skipping PR #$NUM"; continue; }
              if [ "$BRANCH_EPOCH" -le "$((NOW - STALL_MIN * 60))" ]; then
                MODE="repair_stalled"
              fi
            fi
            ;;
        esac
        ;;
    esac
  elif [ "$RUN_RC" -eq 3 ]; then
    if [ "$CREATED" -le "$((NOW - NO_RUN_GRACE_MIN * 60))" ]; then
      MODE="no_run"
    fi
  else
    warn "cannot list review runs for branch $BRANCH; skipping PR #$NUM"
    continue
  fi

  [ -n "$MODE" ] || { echo "PR #$NUM: healthy"; continue; }

  # --- decide actions ---------------------------------------------------------
  ALERT_EPOCH="$(marker_epoch "$NUM" "${ALERT_MARKER}${MODE}")" || ALERT_EPOCH=""
  ALERT_DUE=1
  if [ -n "$ALERT_EPOCH" ] && [ "$ALERT_EPOCH" -gt 0 ]; then
    [ "$((NOW - ALERT_EPOCH))" -lt "$((ALERT_COOLDOWN_H * 3600))" ] && ALERT_DUE=0
  fi

  RETRIGGER=""
  if [ "$MODE" = "no_run" ]; then
    HITS=""
    if ! HITS="$(control_hits "$NUM")"; then
      RETRIGGER="error" # fail closed: without file visibility, never retrigger
    elif [ -n "$HITS" ]; then
      RETRIGGER="control"
    else
      RT_EPOCH="$(marker_epoch "$NUM" "$RETRIGGER_MARKER")" || RT_EPOCH=""
      if [ -n "$RT_EPOCH" ] && [ "$RT_EPOCH" -gt 0 ] &&
        [ "$((NOW - RT_EPOCH))" -lt "$((RETRIGGER_COOLDOWN_H * 3600))" ]; then
        RETRIGGER="cooldown"
      else
        RETRIGGER="due"
      fi
    fi
  fi

  case "$MODE" in
    run_failed)
      ACTION="查看上面 run 的日志定位失败原因（常见：workflow 文件解析错误、runner 基础设施故障）；处理后 re-run 该 workflow，或 close+reopen 本 PR 重新触发审计。"
      ;;
    stuck)
      ACTION="run 已停留在 ${RUN_STATUS} 状态超过 ${STUCK_MIN} 分钟：确认是否卡死，必要时 re-run 或 close+reopen 重新触发审计。"
      ;;
    repair_stalled)
      ACTION="PR 已被退回（agent-failed）但分支已超过 ${STALL_MIN} 分钟无推进：检查 agent-scheduler / pr-repair 的修复队列是否在运行，必要时手动 dispatch 修复。"
      ;;
    no_run)
      if [ "$RETRIGGER" = "control" ]; then
        ACTION="PR 打开后审计从未启动；但本 PR 修改了审计/合并控制路径，永不自动重触发（never auto-retriggered: merge-control path），请人工 re-run pr-review workflow。"
      elif [ "$RETRIGGER" = "due" ]; then
        ACTION="PR 打开后审计从未启动（事件可能丢失）：本评论之后 watchdog 将自动 close+reopen 一次以重新触发审计（限频：每 PR 每 ${RETRIGGER_COOLDOWN_H} 小时至多一次）。"
      else
        ACTION="PR 打开后审计从未启动：上次自动重触发仍在冷却期内或无法判定，若仍未开始请人工 re-run pr-review workflow。"
      fi
      ;;
  esac

  BODY="$(mktemp "${TMPDIR:-/tmp}/review-watchdog-body.XXXXXX")"
  {
    printf '%s\n' "🕵️ review-watchdog（issue #56）：发现审计链路静默失败，PR 可能已搁浅。"
    printf '%s\n' ""
    printf '%s\n' "- PR: #$NUM"
    printf '%s\n' "- Failure mode: $MODE"
    printf '%s\n' "- $RUN_LINE"
    printf '%s\n' "- Suggested action: $ACTION"
    printf '%s\n' ""
    printf '%s\n' "${ALERT_MARKER}${MODE} pr=$NUM run=${RUN_ID:--} -->"
    if [ "$RETRIGGER" = "due" ]; then
      printf '%s\n' "<!-- review-watchdog:action=retrigger pr=$NUM -->"
    fi
  } > "$BODY"

  ALERT_POSTED=0
  if [ "$ALERT_DUE" -eq 1 ]; then
    if gh pr comment "$NUM" --body-file "$BODY"; then
      echo "PR #$NUM: $MODE -> alert posted"
      ALERT_POSTED=1
    else
      warn "posting the alert for PR #$NUM failed"
    fi
  else
    echo "PR #$NUM: $MODE -> alert rate-limited (cooldown ${ALERT_COOLDOWN_H}h)"
  fi
  rm -f "$BODY"

  if [ "$RETRIGGER" = "due" ]; then
    # The receipt marker lives in the alert body: without a posted alert the
    # next scan would see no receipt and re-trigger again, uncooled.
    if [ "$ALERT_POSTED" -eq 1 ]; then
      if gh pr close "$NUM" && gh pr reopen "$NUM"; then
        echo "PR #$NUM: re-triggered the review via close+reopen"
      else
        warn "close+reopen of PR #$NUM failed; the re-trigger did not complete"
      fi
    else
      echo "PR #$NUM: re-trigger skipped (its receipt-carrying alert was not posted; retried next scan)"
    fi
  elif [ "$RETRIGGER" = "control" ]; then
    echo "PR #$NUM: re-trigger skipped (merge-control path, human decides)"
  elif [ "$RETRIGGER" = "cooldown" ]; then
    echo "PR #$NUM: re-trigger rate-limited (cooldown ${RETRIGGER_COOLDOWN_H}h)"
  elif [ "$RETRIGGER" = "error" ]; then
    echo "PR #$NUM: re-trigger skipped (cannot inspect PR files; fail-closed)"
  fi
done

exit 0
