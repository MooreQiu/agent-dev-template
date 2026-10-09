#!/usr/bin/env bash
# Reviewer bot identity resolution (issue #36).
#
# The independent reviewer publishes its report as PR comments under a bot
# identity (github-actions[bot], or the deployment's GitHub App bot). Since
# issue #19, merge authorization comes exclusively from the structured
# verdict artifact written by scripts/review-verdict.sh -- bot comments are
# display-only. This resolver exists so every place that needs to recognize
# the reviewer bot for display/filtering (audit-trail attribution, operator
# runbooks, any future comment-based check) reads ONE per-deployment
# configuration instead of a hardcoded App name: GitHub App names occupy a
# global, site-wide namespace, so no fixed name can work for every
# deployment of this template.
#
# Configuration (repository Actions variable, mapped into workflow env):
#   AGENT_REVIEWER_BOT_LOGIN   the reviewer App's bot login, "<slug>[bot]"
#
# Fail-closed resolution:
#   - well-formed variable   -> allowlist = github-actions[bot] + <variable>
#   - unset / empty / malformed -> allowlist = github-actions[bot] only, and
#     a warning on stderr names the variable
# Matching is exact (no loose [bot]-suffix stripping, no case folding):
# unknown bots are never admitted. The allowlist never grants merge
# authorization; only the verdict artifact does.
#
# Usage:
#   scripts/reviewer-identity.sh list           allowlisted logins, one per line
#   scripts/reviewer-identity.sh check <login>  exit 0 = allowlisted (exact
#                                               match), exit 1 = unknown bot
#
# Exit codes: 0 ok, 1 not allowlisted, 2 usage error.
set -u

DEFAULT_LOGIN="github-actions[bot]"

usage() {
  cat >&2 <<'EOF'
Usage:
  reviewer-identity.sh list
  reviewer-identity.sh check <login>
EOF
  exit 2
}

# Exactly "<slug>[bot]" where the slug is 1-39 chars of [a-z0-9-] starting
# with an alphanumeric (GitHub logins cap at 39 characters). Anything else
# -- uppercase, spaces, underscores, a missing or misplaced [bot], a
# too-long slug -- is malformed and therefore ignored.
well_formed() { # <value>
  v="$1"
  case "$v" in
    *"[bot]") ;;
    *) return 1 ;;
  esac
  slug="${v%?????}" # strip the 5-char "[bot]" suffix just confirmed
  case "$slug" in
    "" | *[!a-z0-9-]*) return 1 ;;
  esac
  case "$slug" in
    [!a-z0-9]*) return 1 ;;
  esac
  [ "${#slug}" -le 39 ] || return 1
  return 0
}

allowlist() { # effective reviewer logins on stdout, the default first
  configured="${AGENT_REVIEWER_BOT_LOGIN:-}"
  printf '%s\n' "$DEFAULT_LOGIN"
  [ -n "$configured" ] || return 0
  if well_formed "$configured"; then
    [ "$configured" = "$DEFAULT_LOGIN" ] && return 0
    printf '%s\n' "$configured"
  else
    echo "reviewer-identity: ignoring malformed AGENT_REVIEWER_BOT_LOGIN (got: $configured); only $DEFAULT_LOGIN is recognized; expected \"<slug>[bot]\" (see docs/GITHUB_APP_SETUP.md)" >&2
  fi
}

[ $# -ge 1 ] || usage
case "$1" in
  list)
    [ $# -eq 1 ] || usage
    allowlist
    ;;
  check)
    [ $# -eq 2 ] || usage
    login="$2"
    # Exact string equality per line; the queried login never undergoes
    # normalization, so look-alikes (case, prefixes, missing suffix) fail.
    while IFS= read -r allowed; do
      [ "$login" = "$allowed" ] && exit 0
    done <<EOF
$(allowlist)
EOF
    exit 1
    ;;
  *) usage ;;
esac
