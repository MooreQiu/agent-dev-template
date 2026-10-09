#!/usr/bin/env bash
# Mirror .claude/skills (single maintained source) into .codex/skills so
# repository skills are discoverable by both Claude Code and Codex, and
# refresh the Codex spec-kit manifest hashes. See docs/AGENT_ROLES.md.
#
# Usage:
#   scripts/sync-skills.sh          # sync copies + regenerate manifest
#   scripts/sync-skills.sh --check  # exit 1 with a drift report, no writes
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
SRC="$REPO_ROOT/.claude/skills"
DST="$REPO_ROOT/.codex/skills"
MANIFEST="$REPO_ROOT/.specify/integrations/codex.manifest.json"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

hash256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

drift=0

# Source -> destination sync (or drift detection).
for src_md in "$SRC"/*/SKILL.md; do
  [ -f "$src_md" ] || continue
  name="$(basename "$(dirname "$src_md")")"
  dst_md="$DST/$name/SKILL.md"
  if [ "$CHECK" -eq 1 ]; then
    if [ ! -f "$dst_md" ] || ! cmp -s "$src_md" "$dst_md"; then
      echo "DRIFT: $name is missing or differs in .codex/skills" >&2
      drift=1
    fi
  else
    mkdir -p "$DST/$name"
    cp "$src_md" "$dst_md"
    echo "synced: $name"
  fi
done

# Destination-only skills have no source and are also drift.
for dst_dir in "$DST"/*/; do
  [ -d "$dst_dir" ] || continue
  name="$(basename "$dst_dir")"
  if [ ! -f "$SRC/$name/SKILL.md" ]; then
    echo "DRIFT: $name exists only in .codex/skills (no source)" >&2
    drift=1
  fi
done

# Manifest hashes must match the synced files.
if [ "$CHECK" -eq 1 ]; then
  if [ -f "$MANIFEST" ]; then
    while read -r p h; do
      [ -n "$p" ] || continue
      if [ ! -f "$REPO_ROOT/$p" ] || [ "$h" != "$(hash256 "$REPO_ROOT/$p")" ]; then
        echo "DRIFT: manifest hash mismatch for $p" >&2
        drift=1
      fi
    done < <(sed -n 's/^    "\([^"]*\)": "\([0-9a-f]\{64\}\)".*/\1 \2/p' "$MANIFEST")
  else
    echo "DRIFT: $MANIFEST is missing" >&2
    drift=1
  fi
  if [ "$drift" -eq 0 ]; then
    echo "skills in sync"
  else
    echo "run scripts/sync-skills.sh to repair" >&2
  fi
  exit "$drift"
fi

# Regenerate the manifest from the actual synced files.
installed_at="$(sed -n 's/.*"installed_at": "\([^"]*\)".*/\1/p' "$MANIFEST" 2>/dev/null)"
[ -n "$installed_at" ] || installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
version="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$REPO_ROOT/.specify/integration.json" 2>/dev/null)"
[ -n "$version" ] || version="unknown"

{
  printf '{\n'
  printf '  "integration": "codex",\n'
  printf '  "version": "%s",\n' "$version"
  printf '  "installed_at": "%s",\n' "$installed_at"
  printf '  "files": {\n'
  first=1
  for dst_md in "$DST"/*/SKILL.md; do
    [ -f "$dst_md" ] || continue
    rel="${dst_md#"$REPO_ROOT"/}"
    if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
    printf '    "%s": "%s"' "$rel" "$(hash256 "$dst_md")"
  done
  printf '\n  }\n'
  printf '}\n'
} > "$MANIFEST"
echo "manifest refreshed: ${MANIFEST#"$REPO_ROOT"/}"
