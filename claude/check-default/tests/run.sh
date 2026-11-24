#!/usr/bin/env bash
# Runs the default checks' module tests: bash claude/check-default/tests/run.sh [NAME...] (default: every module).
# Each module's tests run in their own process. Exits 1 when any test fails.
set -u
dir=$(cd "$(dirname "$0")" && pwd)
names=("$@")
if ((${#names[@]} == 0)); then
  for f in "$dir"/*.sh; do
    n=${f##*/}
    n=${n%.sh}
    [[ $n == lib || $n == run ]] || names+=("$n")
  done
fi
rc=0
for n in "${names[@]}"; do
  echo "== $n"
  bash "$dir/$n.sh" || rc=1
done
exit $rc
