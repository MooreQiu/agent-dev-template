#!/usr/bin/env bash
# Reproducible environment bootstrap for both implementation and review
# environments: validate the machine-readable project configuration
# (.agent/project.json), install dependencies with lockfile semantics, install
# PINNED agent tooling, and verify integrations, model authentication and
# non-interactive execution permissions -- failing fast with an actionable
# error instead of silently waiting for an interactive prompt.
# See docs/AGENT_ROLES.md and AGENTS.md.
#
# Usage:
#   scripts/bootstrap-env.sh           # full bootstrap (installs + verifies)
#   scripts/bootstrap-env.sh --check   # verify configuration and prerequisites
#                                      # only; no installs, no integration
#                                      # presence check (tooling not installed)
#
# Exit codes: 0 = ready, 1 = requirement failure, 2 = usage error.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
PROJECT_FILE="$REPO_ROOT/.agent/project.json"
PREFLIGHT="$SELF_DIR/agent-preflight.sh"

usage() {
  printf '%s\n' \
    "Usage: scripts/bootstrap-env.sh [--check]" \
    "  --check  validate configuration and prerequisites only (no installs)" \
    "Project runtime and commands are defined in .agent/project.json;" \
    "run from the repository root."
}

die() { # die <exit-code> <message...>
  code=$1; shift
  printf 'ERROR: %s\n' "$*" >&2
  exit "$code"
}

# --- minimal JSON access (same controlled format as agent-preflight.sh) -----

project_section() {
  sed -n "/^  \"$1\": {/,/^  }/p" "$PROJECT_FILE" | sed '1d;$d'
}

project_scalar() { # project_scalar <section> <key>
  printf '%s\n' "$1" | sed -n "s/^ *\"$2\": \"\(.*\)\",\{0,1\}\$/\1/p"
}

project_list() { # project_list <block> <key> -- space-separated array values
  printf '%s\n' "$1" | sed -n "s/^ *\"$2\": \[\(.*\)\],\{0,1\}\$/\1/p" \
    | tr ',' '\n' | sed 's/^ *"//; s/" *$//' | sed '/^$/d' | tr '\n' ' '
}

# --- entry -------------------------------------------------------------------

CHECK=0
if [ "${1:-}" = "--check" ]; then
  CHECK=1
  shift
elif [ $# -gt 0 ]; then
  usage >&2
  die 2 "unknown argument '$1'"
fi

[ "$(pwd)" = "$REPO_ROOT" ] \
  || die 1 "wrong working directory: '$(pwd)'; run from the repository root: cd $REPO_ROOT"

# 1. configuration (single source of truth, rejects placeholders)
bash "$PREFLIGHT" verify-project >/dev/null \
  || die 1 "invalid project configuration (.agent/project.json); run 'scripts/agent-preflight.sh verify-project'"

runtime="$(project_section runtime)"
commands="$(project_section commands)"
tooling="$(project_section agent_tooling)"
auth_block="$(project_section model_auth)"
integrations="$(project_list "$(cat "$PROJECT_FILE")" integrations)"
auth_envs="$(project_list "$auth_block" any_of_env)"
rt_name="$(project_scalar "$runtime" name)"
rt_version="$(project_scalar "$runtime" version)"
rt_lockfile="$(project_scalar "$runtime" lockfile)"
cfg_install="$(project_scalar "$commands" install)"
pin="$(project_scalar "$tooling" claude_code)"

# 2. runtime prerequisites
if [ "$rt_name" = "node" ]; then
  for t in node npm; do
    command -v "$t" >/dev/null 2>&1 \
      || die 1 "required runtime tool $t not found in PATH (runtime: node $rt_version)"
  done
  node_version="$(node --version 2>/dev/null)" \
    || die 1 "runtime check failed: 'node --version' exited nonzero"
  # The pin is a floor, not an exact version: the pinned agent tooling only
  # declares a minimum engine (claude-code requires node >= 22), so machines
  # with a newer default runtime must bootstrap fine while older ones fail.
  node_major="${node_version#v}"; node_major="${node_major%%.*}"
  pin_major="${rt_version%%.*}"
  case "$node_major" in
    '' | *[!0-9]*)
      die 1 "runtime check failed: unparsable node version '$node_version'"
      ;;
  esac
  if [ "$node_major" -lt "$pin_major" ]; then
    die 1 "runtime version mismatch: .agent/project.json requires node >= $rt_version, found $node_version; align the environment or update the configuration"
  fi
fi

# 3. model authentication (presence only -- values are never printed)
auth_ok=0
for v in $auth_envs; do
  [ -n "$(printenv "$v" 2>/dev/null)" ] && auth_ok=1
done
[ "$auth_ok" -eq 1 ] \
  || die 1 "model authentication missing: set one of:$auth_envs (values are never printed)"

# 4. non-interactive execution permissions: fail fast instead of prompting
export GIT_TERMINAL_PROMPT=0
export GH_PROMPT_DISABLED=1
command -v gh >/dev/null 2>&1 \
  || die 1 "required tool gh not found in PATH (non-interactive execution needs it)"
gh auth status >/dev/null 2>&1 \
  || die 1 "gh is not authenticated; a non-interactive run would hang (set GITHUB_TOKEN or run 'gh auth login')"
if [ -n "${GITHUB_ENV:-}" ] && touch "$GITHUB_ENV" 2>/dev/null; then
  printf 'GIT_TERMINAL_PROMPT=0\nGH_PROMPT_DISABLED=1\n' >> "$GITHUB_ENV"
fi

# 5. installs (skipped by --check)
if [ "$CHECK" -eq 0 ]; then
  if [ "$rt_name" = "node" ]; then
    lock="$rt_lockfile"
    if [ -z "$lock" ]; then
      for f in package-lock.json yarn.lock pnpm-lock.yaml; do
        [ -f "$REPO_ROOT/$f" ] && lock=$f && break
      done
    fi
    case "$lock" in
      package-lock.json) install_cmd="npm ci" ;;
      yarn.lock) install_cmd="yarn install --frozen-lockfile" ;;
      pnpm-lock.yaml) install_cmd="pnpm install --frozen-lockfile" ;;
      *) install_cmd="$cfg_install" ;;
    esac
  else
    install_cmd="$cfg_install"
  fi

  printf 'installing dependencies: %s\n' "$install_cmd"
  $install_cmd || die 1 "dependency installation failed: $install_cmd"

  command -v npm >/dev/null 2>&1 \
    || die 1 "required tool npm not found in PATH (needed for agent tooling)"
  printf 'installing pinned agent tooling: @anthropic-ai/claude-code@%s\n' "$pin"
  npm install -g "@anthropic-ai/claude-code@$pin" \
    || die 1 "failed to install pinned agent tooling @anthropic-ai/claude-code@$pin"

  for i in $integrations; do
    case "$i" in
      claude)
        command -v claude >/dev/null 2>&1 \
          || die 1 "required integration 'claude' missing from PATH after bootstrap"
        ;;
    esac
  done
fi

if [ "$CHECK" -eq 1 ]; then
  printf 'prerequisites verified, check only (installs skipped) -- runtime: %s %s, auth: ok, non-interactive: ok\n' \
    "$rt_name" "$rt_version"
else
  printf 'environment ready -- runtime: %s %s, integrations:%s, auth: ok, non-interactive: ok\n' \
    "$rt_name" "$rt_version" "$integrations"
fi
