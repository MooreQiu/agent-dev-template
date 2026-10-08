#!/usr/bin/env bash
# Acceptance tests for issue #1: .editorconfig base formatting conventions.
# Usage: bash tests/test-editorconfig.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/.editorconfig"
failures=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

# section_value <section> <key>: print the value of <key> inside ini <section>.
# An empty <section> matches top-level keys (before the first section header).
section_value() {
  awk -v target="[$1]" -v key="$2" '
    BEGIN { in_target = (target == "[]") }
    /^[ \t]*[#;]/ { next }
    /^[ \t]*\[/ {
      header = $0
      sub(/^[ \t]+/, "", header); sub(/[ \t]+$/, "", header)
      in_target = (header == target)
      next
    }
    in_target && index($0, "=") > 0 {
      k = tolower(substr($0, 1, index($0, "=") - 1))
      v = substr($0, index($0, "=") + 1)
      sub(/^[ \t]+/, "", k); sub(/[ \t]+$/, "", k)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (k == tolower(key)) { print v; exit }
    }
  ' "$FILE" 2>/dev/null
}

# assert_eq <actual> <expected> <description>
assert_eq() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3 (expected [$2], got [${1:-<none>}])"
  fi
}

if [ ! -f "$FILE" ]; then
  fail ".editorconfig exists at repository root"
  echo
  echo "1 failure; run aborted: .editorconfig not found"
  exit 1
fi
pass ".editorconfig exists at repository root"

# Acceptance 1: defaults for all files
assert_eq "$(section_value '' 'root')"                    "true"    "root = true marks the repository root config"
assert_eq "$(section_value '*' 'charset')"                "utf-8"   "[*] default charset is utf-8"
assert_eq "$(section_value '*' 'end_of_line')"            "lf"      "[*] default end_of_line is lf"
assert_eq "$(section_value '*' 'insert_final_newline')"   "true"    "[*] default insert_final_newline is true"
assert_eq "$(section_value '*' 'indent_style')"           "space"   "[*] default indent_style is space"
assert_eq "$(section_value '*' 'indent_size')"            "2"       "[*] default indent_size is 2"
assert_eq "$(section_value '*' 'trim_trailing_whitespace')" "true"  "[*] trailing whitespace is trimmed by default"

# Acceptance 2: Markdown keeps trailing whitespace (hard line breaks)
assert_eq "$(section_value '*.md' 'trim_trailing_whitespace')" "false" "[*.md] keeps trailing whitespace"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
