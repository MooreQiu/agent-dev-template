#!/usr/bin/env bash
# Role preflight: before an agent executes as a role (specify / implement /
# review), verify the required instruction files, specification artifacts,
# skills (both harness copies), supporting scripts, tools and working
# directory; stop with an actionable error when anything is missing, and
# write a run record (role, model, instruction revision, skill hashes).
# Also validates the machine-readable project configuration
# (.agent/project.json) so autonomous development never starts against
# unresolved placeholders or missing commands. See docs/AGENT_ROLES.md.
#
# Usage:
#   scripts/agent-preflight.sh verify <role>
#   scripts/agent-preflight.sh verify-project
#   scripts/agent-preflight.sh note-invocation <role> <skill> [skill...]
#
# Exit codes: 0 = pass, 1 = requirement failure, 2 = usage error.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
ROLES_FILE="$REPO_ROOT/.agent/roles.json"
PROJECT_FILE="$REPO_ROOT/.agent/project.json"
RUNS_DIR="$REPO_ROOT/.agent/runs"

usage() {
  printf '%s\n' \
    "Usage: scripts/agent-preflight.sh verify <role>" \
    "       scripts/agent-preflight.sh verify-project" \
    "       scripts/agent-preflight.sh note-invocation <role> <skill> [skill...]" \
    "Roles are defined in .agent/roles.json; the project runtime, commands," \
    "and pinned agent tooling are defined in .agent/project.json." \
    "Run from the repository root."
}

die() { # die <exit-code> <message...>
  code=$1; shift
  printf 'ERROR: %s\n' "$*" >&2
  exit "$code"
}

# --- minimal JSON access for the controlled roles.json format -------------
# (one key per line, flat role objects, single-line string arrays)

role_block() { # role_block <role> -- role object body, empty if absent
  [ -f "$ROLES_FILE" ] || return 1
  sed -n "/^    \"$1\": {/,/^    }/p" "$ROLES_FILE" | sed '1d;$d'
}

block_list() { # block_list <block> <key> -- space-separated array values
  printf '%s\n' "$1" | sed -n "s/^ *\"$2\": \[\(.*\)\],\{0,1\}\$/\1/p" \
    | tr ',' '\n' | sed 's/^ *"//; s/" *$//' | tr '\n' ' '
}

manifest_scalar() { # manifest_scalar <key-path-block> <key>
  printf '%s\n' "$1" | sed -n "s/^ *\"$2\": \"\(.*\)\",\{0,1\}\$/\1/p"
}

valid_roles() {
  sed -n 's/^    "\([a-z][a-z-]*\)": {.*/\1/p' "$ROLES_FILE" | tr '\n' ' '
}

# --- project configuration (.agent/project.json) ----------------------------

# Minimal JSON access for the controlled project.json format (two-space
# nesting, one key per line, single-line string and array values).

project_section() { # project_section <name> -- section body, empty if absent
  [ -f "$PROJECT_FILE" ] || return 1
  sed -n "/^  \"$1\": {/,/^  }/p" "$PROJECT_FILE" | sed '1d;$d'
}

project_scalar() { # project_scalar <section> <key> -- scalar value
  printf '%s\n' "$1" | sed -n "s/^ *\"$2\": \"\(.*\)\",\{0,1\}\$/\1/p"
}

project_list() { # project_list <block> <key> -- space-separated array values
  printf '%s\n' "$1" | sed -n "s/^ *\"$2\": \[\(.*\)\],\{0,1\}\$/\1/p" \
    | tr ',' '\n' | sed 's/^ *"//; s/" *$//' | sed '/^$/d' | tr '\n' ' '
}

is_placeholder() { # is_placeholder <value> -- true when unresolved template text
  printf '%s\n' "$1" | grep -Eq '待填|TODO|TBD'
}

SUPPORTED_LOCKFILES="package-lock.json yarn.lock pnpm-lock.yaml"
SUPPORTED_INTEGRATIONS="claude codex gemini opencode"

# integration name -> pinned-tooling key in agent_tooling (issue #23:
# every enabled integration must pin its CLI exactly)
integration_pin_key() { # integration_pin_key <integration>
  case "$1" in
    claude) printf 'claude_code' ;;
    codex) printf 'codex_cli' ;;
    gemini) printf 'gemini_cli' ;;
    opencode) printf 'opencode_cli' ;;
  esac
}

validate_project_config() { # prints ERROR lines to stderr; rc 1 on failure
  [ -f "$PROJECT_FILE" ] || {
    printf 'ERROR: project configuration not found: .agent/project.json (see docs/AGENT_ROLES.md)\n' >&2
    return 1
  }

  runtime="$(project_section runtime)"
  commands="$(project_section commands)"
  tooling="$(project_section agent_tooling)"
  auth_block="$(project_section model_auth)"
  integrations="$(project_list "$(cat "$PROJECT_FILE")" integrations)"
  auth_envs="$(project_list "$auth_block" any_of_env)"

  errors=0

  rt_name="$(project_scalar "$runtime" name)"
  rt_version="$(project_scalar "$runtime" version)"
  rt_lockfile="$(project_scalar "$runtime" lockfile)"

  if [ -z "$rt_name" ] || is_placeholder "$rt_name"; then
    printf 'ERROR: runtime.name is required in .agent/project.json (unresolved placeholder)\n' >&2
    errors=$((errors + 1))
  fi
  if [ "$rt_name" = "node" ]; then
    if [ -z "$rt_version" ] || is_placeholder "$rt_version" || \
       ! printf '%s\n' "$rt_version" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
      printf 'ERROR: runtime.version must be an exact node version (got '%s')\n' "$rt_version" >&2
      errors=$((errors + 1))
    fi
  fi
  if [ -n "$rt_lockfile" ]; then
    if ! printf '%s\n' "$rt_lockfile" | grep -Eq "^($(
      printf '%s' "$SUPPORTED_LOCKFILES" | tr ' ' '|'
    ))$"; then
      printf 'ERROR: unsupported runtime.lockfile '%s' (supported: %s)\n' \
        "$rt_lockfile" "$SUPPORTED_LOCKFILES" >&2
      errors=$((errors + 1))
    elif [ ! -f "$REPO_ROOT/$rt_lockfile" ]; then
      printf 'ERROR: runtime.lockfile '%s' is declared but missing from the repository\n' \
        "$rt_lockfile" >&2
      errors=$((errors + 1))
    fi
  fi

  for key in install test; do
    val="$(project_scalar "$commands" "$key")"
    if [ -z "$val" ]; then
      printf 'ERROR: commands.%s is required in .agent/project.json\n' "$key" >&2
      errors=$((errors + 1))
    elif is_placeholder "$val"; then
      printf 'ERROR: commands.%s still contains an unresolved placeholder: '%s'\n' "$key" "$val" >&2
      errors=$((errors + 1))
    fi
  done
  for key in build lint typecheck; do
    val="$(project_scalar "$commands" "$key")"
    if [ -n "$val" ] && is_placeholder "$val"; then
      printf 'ERROR: commands.%s still contains an unresolved placeholder: '%s'\n' "$key" "$val" >&2
      errors=$((errors + 1))
    fi
  done

  pin="$(project_scalar "$tooling" claude_code)"
  if ! printf '%s\n' "$pin" | grep -Eq '^[0-9]+(\.[0-9]+)+$'; then
    printf 'ERROR: agent_tooling.claude_code must be an exact pinned version, not '%s'\n' "$pin" >&2
    errors=$((errors + 1))
  fi

  if [ -z "$integrations" ]; then
    printf 'ERROR: integrations must list at least one agent integration\n' >&2
    errors=$((errors + 1))
  fi
  for i in $integrations; do
    case " $SUPPORTED_INTEGRATIONS " in
      *" $i "*) ;;
      *)
        printf 'ERROR: unsupported integration '%s' (supported: %s)\n' \
          "$i" "$SUPPORTED_INTEGRATIONS" >&2
        errors=$((errors + 1))
        continue
        ;;
    esac
    pin_key="$(integration_pin_key "$i")"
    pin="$(project_scalar "$tooling" "$pin_key")"
    if ! printf '%s\n' "$pin" | grep -Eq '^[0-9]+(\.[0-9]+)+$'; then
      printf 'ERROR: agent_tooling.%s must be an exact pinned version for integration '%s', not '%s'\n' \
        "$pin_key" "$i" "$pin" >&2
      errors=$((errors + 1))
    fi
  done

  if [ -z "$auth_envs" ]; then
    printf 'ERROR: model_auth.any_of_env must list at least one environment variable\n' >&2
    errors=$((errors + 1))
  fi

  [ "$errors" -eq 0 ] || return 1
  return 0
}

cmd_verify_project() {
  [ "$(pwd)" = "$REPO_ROOT" ] \
    || die 1 "wrong working directory: '$(pwd)'; run from the repository root: cd $REPO_ROOT"

  validate_project_config \
    || die 1 "invalid project configuration (.agent/project.json); fix the errors above"

  runtime="$(project_section runtime)"
  commands="$(project_section commands)"
  tooling="$(project_section agent_tooling)"
  auth_block="$(project_section model_auth)"
  integrations="$(project_list "$(cat "$PROJECT_FILE")" integrations)"
  auth_envs="$(project_list "$auth_block" any_of_env)"

  rt_name="$(project_scalar "$runtime" name)"
  rt_version="$(project_scalar "$runtime" version)"
  rt_lockfile="$(project_scalar "$runtime" lockfile)"
  [ -n "$rt_lockfile" ] || rt_lockfile="auto"

  printf 'project configuration valid (.agent/project.json)\n'
  printf '  runtime: %s %s (lockfile: %s)\n' "$rt_name" "$rt_version" "$rt_lockfile"
  for key in install build test lint typecheck; do
    val="$(project_scalar "$commands" "$key")"
    [ -n "$val" ] || val="(not configured)"
    printf '  %s: %s\n' "$key" "$val"
  done
  printf '  integrations:%s\n' "$integrations"
  for i in $integrations; do
    printf '  agent tooling: %s pinned as agent_tooling.%s=%s\n' \
      "$i" "$(integration_pin_key "$i")" "$(project_scalar "$tooling" "$(integration_pin_key "$i")")"
  done
  printf '  model auth env:%s\n' "$auth_envs"
}

# --- verify ----------------------------------------------------------------

cmd_verify() {
  role=$1

  [ -f "$ROLES_FILE" ] \
    || die 1 "required manifest not found: .agent/roles.json (see docs/AGENT_ROLES.md)"

  block="$(role_block "$role")"
  [ -n "$block" ] \
    || die 2 "unknown role '$role'; valid roles: $(valid_roles)"

  cwd="$(pwd)"
  [ "$cwd" = "$REPO_ROOT" ] \
    || die 1 "wrong working directory: '$cwd'; run from the repository root: cd $REPO_ROOT"

  validate_project_config || {
    die 1 "invalid project configuration (.agent/project.json); run 'scripts/agent-preflight.sh verify-project'"
  }

  instructions="$(block_list "$block" instructions)"
  artifacts="$(block_list "$block" artifacts)"
  scripts="$(block_list "$block" scripts)"
  skills="$(block_list "$block" skills)"
  tools="$(block_list "$block" tools)"

  sources_block="$(sed -n '/^  "skill_sources": {/,/^  },\{0,1\}$/p' "$ROLES_FILE" | sed '1d;$d')"
  claude_dir="$(manifest_scalar "$sources_block" claude)"
  codex_dir="$(manifest_scalar "$sources_block" codex)"
  [ -n "$claude_dir" ] && [ -n "$codex_dir" ] \
    || die 1 "malformed .agent/roles.json: skill_sources for claude and codex are required"

  errors=0

  for f in $instructions $artifacts; do
    if [ ! -f "$REPO_ROOT/$f" ]; then
      printf 'ERROR: missing required file for role %s: %s\n' "'$role'" "$f" >&2
      errors=$((errors + 1))
    fi
  done

  for f in $scripts; do
    if [ ! -f "$REPO_ROOT/$f" ]; then
      printf 'ERROR: missing required script for role %s: %s\n' "'$role'" "$f" >&2
      errors=$((errors + 1))
    elif [ ! -x "$REPO_ROOT/$f" ]; then
      printf 'ERROR: supporting script not executable for role %s: %s (chmod +x)\n' "'$role'" "$f" >&2
      errors=$((errors + 1))
    fi
  done

  for t in $tools; do
    if ! command -v "$t" >/dev/null 2>&1; then
      printf 'ERROR: missing required tool for role %s: %s (not found in PATH)\n' "'$role'" "$t" >&2
      errors=$((errors + 1))
    fi
  done

  skill_hashes=""
  for s in $skills; do
    claude_md="$REPO_ROOT/$claude_dir/$s/SKILL.md"
    codex_md="$REPO_ROOT/$codex_dir/$s/SKILL.md"
    if [ ! -f "$claude_md" ]; then
      printf 'ERROR: missing required skill for role %s: %s (expected %s/%s/SKILL.md)\n' "'$role'" "$s" "$claude_dir" "$s" >&2
      errors=$((errors + 1))
      continue
    fi
    frontmatter="$(sed -n '/^---$/,/^---$/p' "$claude_md")"
    if ! printf '%s\n' "$frontmatter" | grep -q '^name:'; then
      printf 'ERROR: skill %s SKILL.md frontmatter is missing %s\n' "'$s'" "'name:'" >&2
      errors=$((errors + 1))
      continue
    fi
    if ! printf '%s\n' "$frontmatter" | grep -q '^description:'; then
      printf 'ERROR: skill %s SKILL.md frontmatter is missing %s\n' "'$s'" "'description:'" >&2
      errors=$((errors + 1))
      continue
    fi
    if [ ! -f "$codex_md" ]; then
      printf 'ERROR: missing required skill for role %s: %s in %s (run scripts/sync-skills.sh)\n' "'$role'" "$s" "$codex_dir" >&2
      errors=$((errors + 1))
      continue
    fi
    if ! cmp -s "$claude_md" "$codex_md"; then
      printf 'ERROR: skill %s out of sync between %s and %s; run scripts/sync-skills.sh\n' "'$s'" "$claude_dir" "$codex_dir" >&2
      errors=$((errors + 1))
      continue
    fi
    skill_hashes="$skill_hashes $s:$(git hash-object "$claude_md")"
  done

  [ "$errors" -eq 0 ] || die 1 "$errors unmet requirement(s) for role '$role'; fix the errors above before executing"

  # --- write the run record ------------------------------------------------
  mkdir -p "$RUNS_DIR"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  commit="$(git rev-parse --verify HEAD 2>/dev/null || echo none)"
  model="${AGENT_MODEL:-${ANTHROPIC_DEFAULT_SONNET_MODEL:-unset}}"
  rec="$RUNS_DIR/preflight-$role-$stamp-$$.json"

  {
    printf '{\n'
    printf '  "role": "%s",\n' "$role"
    printf '  "recorded_at": "%s",\n' "$now"
    printf '  "model": "%s",\n' "$model"
    printf '  "working_directory": "%s",\n' "$cwd"
    printf '  "instruction_revision": {\n'
    printf '    "commit": "%s",\n' "$commit"
    printf '    "files": {\n'
    n=0
    total=0
    for f in $instructions; do total=$((total + 1)); done
    for f in $instructions; do
      n=$((n + 1))
      if [ "$n" -lt "$total" ]; then comma=','; else comma=''; fi
      printf '      "%s": "%s"%s\n' "$f" "$(git hash-object "$REPO_ROOT/$f")" "$comma"
    done
    printf '    }\n'
    printf '  },\n'
    printf '  "evidence": {\n'
    printf '    "discovered": [\n'
    n=0
    total=0
    for h in $skill_hashes; do total=$((total + 1)); done
    for h in $skill_hashes; do
      n=$((n + 1))
      if [ "$n" -lt "$total" ]; then comma=','; else comma=''; fi
      printf '      {"skill": "%s", "hash": "%s", "sources": ["%s", "%s"]}%s\n' \
        "${h%%:*}" "${h#*:}" "$claude_dir" "$codex_dir" "$comma"
    done
    printf '    ],\n'
    printf '    "invoked": []\n'
    printf '  }\n'
    printf '}\n'
  } > "$rec"

  printf 'role %s preflight passed (%s skills, %s tools)\n' "'$role'" "$total" "$(printf '%s ' $tools | sed 's/ $//')"
  printf 'run record: %s\n' "${rec#"$REPO_ROOT"/}"
}

# --- note-invocation ---------------------------------------------------------

cmd_note() {
  role=$1; shift
  [ $# -gt 0 ] || die 2 "note-invocation requires at least one skill name"

  [ -f "$ROLES_FILE" ] \
    || die 1 "required manifest not found: .agent/roles.json (see docs/AGENT_ROLES.md)"
  block="$(role_block "$role")"
  [ -n "$block" ] || die 2 "unknown role '$role'; valid roles: $(valid_roles)"

  skills="$(block_list "$block" skills)"
  latest="$(ls -t "$RUNS_DIR"/preflight-"$role"-*.json 2>/dev/null | sed -n 1p)"
  [ -n "$latest" ] \
    || die 1 "no run record for role '$role'; run 'scripts/agent-preflight.sh verify $role' first"

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for s in "$@"; do
    case " $skills " in
      *" $s "*) ;;
      *) die 1 "skill '$s' is not required by role '$role' (mapped skills:$(printf ' %s' $skills))" ;;
    esac
    printf '{"role":"%s","skill":"%s","run":"%s","recorded_at":"%s"}\n' \
      "$role" "$s" "${latest##*/}" "$now" >> "$RUNS_DIR/invocations.jsonl"
    printf 'recorded invocation: %s (role %s, run %s)\n' "$s" "'$role'" "${latest##*/}"
  done
}

# --- entry -------------------------------------------------------------------

[ $# -ge 1 ] || { usage >&2; exit 2; }
cmd=$1; shift

case "$cmd" in
  verify)
    [ $# -eq 1 ] || { usage >&2; exit 2; }
    cmd_verify "$1"
    ;;
  verify-project)
    [ $# -eq 0 ] || { usage >&2; exit 2; }
    cmd_verify_project
    ;;
  note-invocation)
    [ $# -ge 2 ] || { usage >&2; exit 2; }
    cmd_note "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    die 2 "unknown command '$cmd'"
    ;;
esac
