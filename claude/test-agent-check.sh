#!/usr/bin/env bash
# Tests for agent-check.sh in throwaway repos: bash claude/test-agent-check.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ac=${AGENT_CHECK:-$here/agent-check.sh} # or the installed one: AGENT_CHECK=$(command -v agent-check)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export XDG_STATE_HOME=$work/state
fails=0

# A repo whose check-fast reports every line containing BAD in changed files,
# breaks when a file named BROKEN exists and notes a skip when one named NOTE does
repo=$work/repo
git init -q "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir "$repo/scripts"
cat >"$repo/scripts/check-fast" <<'EOF'
#!/usr/bin/env bash
cd "$(git rev-parse --show-toplevel)"
[[ -e BROKEN ]] && { echo "tool missing" >&2; exit 3; }
[[ -e NOTE ]] && echo "check-fast: part skipped" >&2
{ git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u |
  while IFS= read -r f; do [[ -f $f ]] && grep -n -H BAD "$f" | sed 's/:\([0-9]*\):.*/:\1: no-bad: remove BAD/'; done |
  grep . && exit 1
exit 0
EOF
chmod +x "$repo/scripts/check-fast"
git -C "$repo" add scripts
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m contract

hook() { jq -n --arg cwd "$1" --arg s "${2:-s1}" '{cwd: $cwd, session_id: $s, hook_event_name: "Stop"}' | "$ac" hook; }

expect() { # expect NAME PATTERN OUTPUT (an empty PATTERN means no output)
  local name=$1 pattern=$2 out=$3
  if [[ -z $pattern && -z $out ]] || [[ -n $pattern && $out =~ $pattern ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: got: ${out:-<nothing>}"
    fails=$((fails + 1))
  fi
}

expect "outside a repo is silent" "" "$(hook "$work")"
mkdir "$work/plain" && git init -q "$work/plain"
expect "repo without check-fast is silent" "" "$(hook "$work/plain")"
expect "clean tree is silent" "" "$(hook "$repo")"

echo good >"$repo/a.txt"
expect "passing check is silent" "" "$(hook "$repo")"

echo BAD >>"$repo/a.txt"
out=$(hook "$repo")
expect "findings block" '"decision": "block"' "$out"
expect "block names the finding" 'a\.txt:2: no-bad' "$out"
expect "same findings again give up" 'turn ended with check-fast findings still open' "$(hook "$repo")"
expect "a settled state is silent" "" "$(hook "$repo")"
expect "another session gets its own block" '"decision": "block"' "$(hook "$repo" s2)"

echo BAD >"$repo/b.txt"
expect "new findings block again" '"decision": "block"' "$(hook "$repo")"
echo good >"$repo/a.txt" && rm "$repo/b.txt"
expect "fixed tree passes silently" "" "$(hook "$repo")"

touch "$repo/BROKEN"
out=$(hook "$repo")
expect "broken check doesn't block" '^\{[^}]*"systemMessage"' "$out"
expect "broken check says so" 'broken \(exit 3\).*tool missing' "$out"
rm "$repo/BROKEN"

if command -v direnv >/dev/null; then
  echo 'export X=1' >"$repo/.envrc"
  out=$(hook "$repo")
  expect "a blocked .envrc is reported, not blocking" '^\{[^}]*"systemMessage".*broken.*is blocked' "$out"
  rm "$repo/.envrc"
fi

touch "$repo/NOTE"
out=$(hook "$repo")
expect "a pass with a note tells the person" '^\{[^}]*"systemMessage".*a note from check-fast.*part skipped' "$out"
echo again >>"$repo/a.txt"
expect "the same note isn't repeated" "" "$(hook "$repo")"
rm "$repo/NOTE"

printf '[extend]\nuseDefault = true\n' >"$repo/.gitleaks.toml"
expect "a check config change is flagged" '\.gitleaks\.toml:0: check-config' "$(hook "$repo")"
rm "$repo/.gitleaks.toml"

printf 'x=1 # shellcheck disable=SC2034\n' >"$repo/c.sh"
printf 'module x\n' >"$repo/go.mod"
out=$(hook "$repo")
expect "added suppression is flagged" 'c\.sh:1: suppression' "$out"
expect "new manifest is flagged" 'go\.mod:0: dependency' "$out"
expect "flags don't block" '^\{[^}]*"systemMessage"' "$out"
echo more >>"$repo/a.txt"
expect "unchanged flags aren't repeated" "" "$(hook "$repo")"

out=$("$ac" run "$repo") || true
expect "run reports pass and flags" 'check-fast \(repo\): pass.*flags' "$out"
echo BAD >>"$repo/a.txt"
rc=0 && out=$("$ac" run "$repo") || rc=$?
expect "run reports findings" 'findings.*a\.txt:[0-9]+: no-bad' "$out"
expect "run exits 1 on findings" '^1$' "$rc"
out=$("$ac" run "$work/plain")
expect "run without check-fast says none" 'none' "$out"

if ((fails > 0)); then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
