#!/usr/bin/env bash
# Runs the default checks' module tests: bash claude/check-default/tests/run.sh [NAME...] (default: every module).
# Each module's tests run in their own process, with the tools agent-check pins on PATH: those of the agent-check
# in $AGENT_CHECK (a build: AGENT_CHECK=result-path/bin/agent-check), else of the installed one. A module whose
# tools aren't there says "skipped". Exits 1 when any test fails.
set -u
dir=$(cd "$(dirname "$0")" && pwd)
ac=${AGENT_CHECK:-$(command -v agent-check || true)}
# The Nix-built agent-check is a script whose PATH line lists its pinned tools
if [[ -n $ac && -f $ac ]] && line=$(grep -m1 '^export PATH=' "$ac"); then
  eval "$line"
fi
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
