#!/usr/bin/env bash
# Cross-run handoff for spec planning and convergence artifacts (issue #44).
#
# Spec Start and Spec Converge upload workflow artifacts that no later run
# ever retrieved, so a fresh runner could not resume planning or convergence
# and silently re-derived everything. This script implements the storage and
# retrieval contract documented in docs/SPEC_ARTIFACTS.md:
#
#   manifest   bind payload files into a versioned bundle description
#              (manifest.json), keyed by feature identity, approved spec
#              revision, and -- for convergence -- the validated target
#              commit; the workflow uploads the manifest with the payload
#   restore    retrieve the newest matching artifact via the gh CLI, validate
#              every binding and hash, and copy the payload into the current
#              checkout so a fresh runner resumes instead of re-deriving
#
# The approved spec and the approval record are protected: bundles never
# contain them and restore never overwrites them (git is their store).
# Payload files are validated completely before anything is copied, so a
# rejected bundle never leaves partial state behind.
#
# Usage:
#   scripts/spec-artifacts.sh manifest <kind> <spec-path> <approved-revision> \
#       [--target <sha>] [--output <file>] <repo-relative-file>...
#   scripts/spec-artifacts.sh restore <kind> <spec-path> <approved-revision> \
#       [--target <sha>] [--json]
#
# <kind>            planning (plan.md/tasks.md) | convergence (findings,
#                   evidence, completion record)
# --target <sha>    validated target commit. manifest: recorded in the
#                   binding (default HEAD). restore: when given, a manifest
#                   bound to a different commit is stale (exit 4); the
#                   converge workflow always passes the current HEAD
# --output <file>   manifest destination (default: the bundle root's
#                   manifest.json)
# --json            print a single machine-readable JSON line on stdout
#
# Retrieval key (the artifact name): spec-<kind>-<feature>-<revision>.
# Bundle layout: manifest.json plus the payload files relative to the bundle
# root (planning: specs/<feature>/, convergence: specs/<feature>/convergence/)
# -- exactly the common prefix upload-artifact computes for those paths.
#
# Exit codes: 0 = ok, 1 = artifact rejected (mismatched, corrupt, ambiguous,
#             or protected), 2 = usage error, 3 = no artifact found
#             (never uploaded, deleted, or expired), 4 = stale (the bundle is
#             bound to a different target commit than --target).
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"

log() { printf '%s\n' "$*" >&2; }
die() { # die <exit-code> <message...>
  code=$1; shift
  printf 'ERROR: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/spec-artifacts.sh manifest <kind> <spec-path> <approved-revision> \
      [--target <sha>] [--output <file>] <repo-relative-file>...
  scripts/spec-artifacts.sh restore <kind> <spec-path> <approved-revision> \
      [--target <sha>] [--json]
Kinds: planning (plan.md/tasks.md), convergence (findings, evidence,
completion record). Contract and exit codes: docs/SPEC_ARTIFACTS.md.
EOF
}

sha256_of() { # sha256_of <file> -> hex digest on stdout
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# --- shared gates: kind, spec path shape, feature identity -------------------
KIND=""
SPEC=""
FEATURE=""
FEATURE_DIR=""
ROOT="" # bundle root: where the workflow upload's common prefix lands

common_gates() { # common_gates <kind> <spec-path>
  KIND=$1; SPEC=$2
  case "$KIND" in
    planning|convergence) ;;
    *) usage; die 2 "unknown kind: $KIND (expected planning or convergence)" ;;
  esac
  case "$SPEC" in
    /*|../*|*/../*|*/..|*\ **) die 2 "spec path must be relative to the repository root: $SPEC" ;;
  esac
  case "$SPEC" in
    */*) ;;
    *) die 2 "spec path must live in a feature directory: specs/<feature>/spec.md (got $SPEC)" ;;
  esac
  [ -f "$REPO_ROOT/$SPEC" ] || die 1 "spec not found: $SPEC"
  FEATURE_DIR="${SPEC%/*}"
  FEATURE="${FEATURE_DIR##*/}"
  [ -n "$FEATURE" ] && [ "$FEATURE" != "specs" ] \
    || die 1 "spec must live in a feature directory: $SPEC (expected specs/<feature>/spec.md)"
  ROOT="$FEATURE_DIR"
  [ "$KIND" = convergence ] && ROOT="$FEATURE_DIR/convergence"
}

protected_path() { # protected_path <repo-relative-path>
  case "$1" in
    "$FEATURE_DIR/spec.md"|"$FEATURE_DIR/approval.json") return 0 ;;
  esac
  return 1
}

REL=""
bundle_rel() { # bundle_rel <repo-relative-path> -> sets REL; prints error and
  # returns 1 when the path is unsafe, outside the bundle root, protected, or
  # the reserved manifest name (never exits: callers own the exit code)
  p=$1
  case "$p" in
    "$ROOT"/*) REL="${p#"$ROOT"/}" ;;
    *)
      printf 'ERROR: artifact file outside the %s bundle root %s: %s\n' "$KIND" "$ROOT" "$p" >&2
      return 1
      ;;
  esac
  case "$REL" in
    ""|/*|*..*|*\ *)
      printf 'ERROR: artifact file has an unsafe bundle path: %s\n' "$p" >&2
      return 1
      ;;
  esac
  if [ "$REL" = manifest.json ]; then
    printf 'ERROR: manifest.json is reserved for the bundle binding: %s\n' "$p" >&2
    return 1
  fi
  if protected_path "$p"; then
    printf 'ERROR: protected path never travels in artifacts: %s (the approved spec and approval record stay in git)\n' "$p" >&2
    return 1
  fi
}

# --- manifest: write the binding record for a bundle -------------------------
cmd_manifest() { # cmd_manifest <kind> <spec> <revision> [options] <file>...
  kind=$1; spec=$2; rev=$3; shift 3
  common_gates "$kind" "$spec"

  cd "$REPO_ROOT" || die 1 "cannot enter repository root: $REPO_ROOT"
  sha="$(git rev-parse --verify --quiet "$rev^{commit}")" \
    || die 1 "unknown revision: $rev"
  spec_blob="$(git rev-parse --verify --quiet "$sha:$SPEC")" \
    || die 1 "approved revision $sha does not contain $SPEC"

  target=""
  output=""
  files=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --target)
        [ $# -ge 2 ] || { usage; die 2 "--target needs a commit argument"; }
        target=$2; shift 2
        ;;
      --output)
        [ $# -ge 2 ] || { usage; die 2 "--output needs a file argument"; }
        output=$2; shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; die 2 "unknown option: $1" ;;
      *) files="$files $1"; shift ;;
    esac
  done
  [ -n "$target" ] \
    || target="$(git rev-parse --verify HEAD^{commit})" \
    || die 1 "cannot resolve the target commit (HEAD)"
  [ -n "$output" ] || output="$ROOT/manifest.json"
  [ -n "${files# }" ] || { usage; die 2 "manifest needs at least one payload file"; }

  # deterministic order; duplicates make the binding ambiguous
  dupes="$(printf '%s\n' $files | LC_ALL=C sort | uniq -d)"
  [ -z "$dupes" ] || die 1 "duplicate artifact files:$(printf '%s\n' $files | LC_ALL=C sort | uniq -d | tr '\n' ' ')"

  entries=""
  count=0
  for f in $(printf '%s\n' $files | LC_ALL=C sort); do
    bundle_rel "$f" || exit 1
    [ -f "$f" ] || die 1 "artifact file not found: $f"
    hash="$(sha256_of "$f")" \
      || die 1 "no sha256 utility found (need sha256sum or shasum)"
    entries="$entries
    {\"path\": \"$f\", \"sha256\": \"$hash\"},"
    count=$((count + 1))
  done
  entries="${entries%,}"
  entries="${entries#
}"
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname "$output")" || die 1 "cannot create $(dirname "$output")"
  {
    printf '{\n'
    printf '  "kind": "%s",\n' "$kind"
    printf '  "feature": "%s",\n' "$FEATURE"
    printf '  "spec": "%s",\n' "$SPEC"
    printf '  "revision": "%s",\n' "$sha"
    printf '  "spec_blob": "%s",\n' "$spec_blob"
    printf '  "target": "%s",\n' "$target"
    printf '  "created_at": "%s",\n' "$created"
    printf '  "files": [\n%s\n  ]\n' "$entries"
    printf '}\n'
  } > "$output"
  log "manifest written: $output ($kind, $FEATURE @ $sha, target $target, $count file(s))"
}

# --- restore: retrieve, validate, and copy the newest bundle -----------------
cmd_restore() { # cmd_restore <kind> <spec> <revision> [options]
  kind=$1; spec=$2; rev=$3; shift 3
  common_gates "$kind" "$spec"

  target_req=""
  json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --target)
        [ $# -ge 2 ] || { usage; die 2 "--target needs a commit argument"; }
        target_req=$2; shift 2
        ;;
      --json) json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; die 2 "unknown option: $1" ;;
      *) usage; die 2 "unexpected argument: $1" ;;
    esac
  done

  cd "$REPO_ROOT" || die 1 "cannot enter repository root: $REPO_ROOT"
  sha="$(git rev-parse --verify --quiet "$rev^{commit}")" \
    || die 1 "unknown revision: $rev"
  spec_blob="$(git rev-parse --verify --quiet "$sha:$SPEC")" \
    || die 1 "approved revision $sha does not contain $SPEC"

  name="spec-$kind-$FEATURE-$sha"
  command -v gh >/dev/null 2>&1 \
    || die 1 "gh is required for artifact retrieval (not found in PATH)"
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
    || die 1 "gh repo view failed; check authentication"

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/spec-artifacts.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT

  # Duplicate uploads across runs are the norm: the newest non-expired
  # artifact for the exact key wins (created_at desc, then id desc) --
  # deterministic, so retrieval is never ambiguous.
  newest="$(gh api "repos/$repo/actions/artifacts?name=$name&per_page=100" \
    --jq '[.artifacts[] | select(.expired == false)] | sort_by([.created_at, .id]) | reverse | .[0] | if . == null then empty else [.id, .created_at] | @tsv end' 2>/dev/null)" \
    || die 1 "gh api artifact list failed for $name; check authentication and the actions: read permission"
  [ -n "$newest" ] \
    || die 3 "no artifact found for $name (never uploaded, deleted, or expired); regenerate by re-running the workflow"
  artifact_id="$(printf '%s\n' "$newest" | cut -f1)"
  artifact_at="$(printf '%s\n' "$newest" | cut -f2)"
  case "$artifact_id" in
    *[!0-9]*|'') die 1 "artifact listing returned an invalid id: '${artifact_id:-<empty>}'" ;;
  esac
  log "retrieving artifact $artifact_id ($name, created $artifact_at)"

  bundle="$WORK/bundle.zip"
  gh api "repos/$repo/actions/artifacts/$artifact_id/zip" \
    -H "Accept: application/zip" > "$bundle" \
    || die 1 "gh api artifact download failed for artifact $artifact_id (deleted or expired mid-flight); re-run the workflow"
  [ -s "$bundle" ] || die 1 "artifact $artifact_id downloaded empty; treat as corrupt"
  command -v unzip >/dev/null 2>&1 \
    || die 1 "unzip is required for artifact retrieval (not found in PATH)"

  # List entries first: never extract a bundle that tries to escape.
  unzip -Z1 "$bundle" >/dev/null 2>&1 \
    || die 1 "artifact $artifact_id is not a readable zip archive"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      /*|*..*|*\ *) die 1 "artifact $artifact_id contains an unsafe path: $entry" ;;
    esac
  done < <(unzip -Z1 "$bundle")

  mkdir -p "$WORK/payload" || die 1 "cannot prepare the extraction directory"
  unzip -oq "$bundle" -d "$WORK/payload" \
    || die 1 "artifact $artifact_id could not be extracted"
  MANIFEST="$WORK/payload/manifest.json"
  [ -f "$MANIFEST" ] \
    || die 1 "artifact $artifact_id has no manifest.json; ambiguous bundle of unknown origin -- reject it and re-run the workflow"

  field() { # field <name> -> first value of the JSON string field
    sed -n "s/.*\"$1\": \"\([^\"]*\)\".*/\1/p" "$MANIFEST" | sed -n 1p
  }
  m_kind="$(field kind)"; m_feature="$(field feature)"; m_spec="$(field spec)"
  m_rev="$(field revision)"; m_blob="$(field spec_blob)"; m_target="$(field target)"

  [ "$m_kind" = "$kind" ] \
    || die 1 "artifact kind mismatch: bundle says '${m_kind:-<empty>}', requested $kind"
  [ "$m_feature" = "$FEATURE" ] \
    || die 1 "artifact feature mismatch: bundle says '${m_feature:-<empty>}', requested $FEATURE"
  [ "$m_spec" = "$SPEC" ] \
    || die 1 "artifact spec mismatch: bundle says '${m_spec:-<empty>}', requested $SPEC"
  [ "$m_rev" = "$sha" ] \
    || die 1 "artifact revision mismatch: bundle says '${m_rev:-<empty>}', requested $sha; the approved revision is immutable"
  [ -n "$m_blob" ] || die 1 "artifact manifest has no spec_blob binding"
  [ "$m_blob" = "$spec_blob" ] \
    || die 1 "artifact spec content mismatch: bundle binds blob $m_blob, the approved revision has $spec_blob"
  [ -n "$m_target" ] || die 1 "artifact manifest has no target binding"
  if [ -n "$target_req" ] && [ "$m_target" != "$target_req" ]; then
    die 4 "stale artifact: bundle is bound to target $m_target, requested $target_req; the validated target moved -- evaluate fresh"
  fi

  listings="$(sed -n 's/^.*{"path": "\([^"]*\)", "sha256": "\([0-9a-fA-F]*\)".*$/\1 \2/p' "$MANIFEST")"
  [ -n "$listings" ] \
    || die 1 "artifact manifest lists no files; nothing to restore and not a valid bundle"

  dup="$(printf '%s\n' "$listings" | awk '{print $1}' | LC_ALL=C sort | uniq -d)"
  [ -z "$dup" ] \
    || die 1 "ambiguous artifact manifest: duplicate path(s):$(printf '%s\n' "$dup" | tr '\n' ' ')"

  restored=""
  expect="manifest.json"
  count=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    p="$(printf '%s\n' "$entry" | awk '{print $1}')"
    want="$(printf '%s\n' "$entry" | awk '{print $2}')"
    bundle_rel "$p" || exit 1
    src="$WORK/payload/$REL"
    [ -f "$src" ] || die 1 "artifact is missing the listed file: $p"
    got="$(sha256_of "$src")" \
      || die 1 "no sha256 utility found (need sha256sum or shasum)"
    [ "$got" = "$want" ] \
      || die 1 "artifact file hash mismatch: $p (the bundle is corrupt or was edited after upload)"
    restored="$restored
$p"
    expect="$expect
$REL"
    count=$((count + 1))
  done <<LISTINGS
$listings
LISTINGS

  # The bundle must contain exactly the manifest listing: anything else is
  # ambiguous about what a restore means.
  actual="$(cd "$WORK/payload" && find . -type f | sed 's#^./##' | LC_ALL=C sort)"
  wanted="$(printf '%s\n' "$expect" | LC_ALL=C sort)"
  [ "$actual" = "$wanted" ] \
    || die 1 "ambiguous artifact: bundle contents do not match the manifest listing (unlisted or missing files)"

  # Validation complete: copy the payload into the checkout.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    rel="${p#"$ROOT"/}"
    dir="$(dirname "$rel")"
    mkdir -p "$ROOT/$dir" || die 1 "cannot create $ROOT/$dir"
    cp "$WORK/payload/$rel" "$p" \
      || die 1 "cannot restore $p into the checkout"
  done <<RESTORED
$restored
RESTORED

  if [ "$json" -eq 1 ]; then
    list=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      list="$list,\"$p\""
    done <<RESTORED
$restored
RESTORED
    printf '{"kind":"%s","feature":"%s","revision":"%s","target":"%s","artifact_id":%s,"restored":[%s]}\n' \
      "$kind" "$FEATURE" "$sha" "$m_target" "$artifact_id" "${list#,}"
  else
    printf 'restored %s file(s) from %s artifact %s (feature=%s spec=%s@%s target=%s)\n' \
      "$count" "$kind" "$artifact_id" "$FEATURE" "$SPEC" "$sha" "$m_target"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      printf '  %s\n' "$p"
    done <<RESTORED
$restored
RESTORED
  fi
  exit 0
}

COMMAND="${1:-}"
[ -n "$COMMAND" ] || { usage; exit 2; }
case "$COMMAND" in
  manifest)
    shift
    [ $# -ge 3 ] || { usage; die 2 "manifest needs <kind> <spec-path> <approved-revision> and payload files"; }
    cmd_manifest "$@"
    ;;
  restore)
    shift
    [ $# -ge 3 ] || { usage; die 2 "restore needs <kind> <spec-path> <approved-revision>"; }
    cmd_restore "$@"
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die 2 "unknown command: $COMMAND" ;;
esac
