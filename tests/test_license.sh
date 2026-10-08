#!/usr/bin/env bash
# Acceptance tests for issue #3: standard MIT LICENSE at the repo root.
# Run: bash tests/test_license.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LICENSE_FILE="$REPO_ROOT/LICENSE"

# Canonical MIT License text (https://opensource.org/licenses/MIT) with the
# year and holder filled in as required by the issue.
EXPECTED='MIT License

Copyright (c) 2026 MooreQiu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.'

failures=0

report() { # report <exit_code> <test_name> [detail]
  if [ "$1" -eq 0 ]; then
    echo "PASS: $2"
  else
    echo "FAIL: $2${3:+ -- $3}"
    failures=$((failures + 1))
  fi
}

# AC1: LICENSE exists at the repo root.
[ -f "$LICENSE_FILE" ]
report $? "LICENSE exists at repo root" "file not found: $LICENSE_FILE"

if [ -f "$LICENSE_FILE" ]; then
  # AC2: copyright line is exactly "Copyright (c) 2026 MooreQiu".
  grep -Fxq "Copyright (c) 2026 MooreQiu" "$LICENSE_FILE"
  report $? "copyright line is 'Copyright (c) 2026 MooreQiu'" \
    "no exact match; got: $(grep -n 'Copyright' "$LICENSE_FILE" || echo none)"

  # AC1: file is the standard MIT text, byte for byte.
  if [ "$(cat "$LICENSE_FILE")" = "$EXPECTED" ]; then
    report 0 "LICENSE matches canonical MIT text"
  else
    report 1 "LICENSE matches canonical MIT text"
    diff <(printf '%s\n' "$EXPECTED") "$LICENSE_FILE" | sed 's/^/    /'
  fi
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
