#!/bin/sh
# Run every acceptance test script in tests/.
set -u
cd "$(dirname "$0")/.."
status=0
for t in tests/test*.sh; do
  echo "== $t"
  bash "$t" || status=1
done
exit "$status"
