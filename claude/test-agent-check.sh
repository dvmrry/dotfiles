#!/usr/bin/env bash
# Tests for agent-check.sh in throwaway repos: bash claude/test-agent-check.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ac=${AGENT_CHECK:-$here/agent-check.sh} # or the installed one: AGENT_CHECK=$(command -v agent-check)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# State, the log and direnv's approvals stay in the throwaway directory
export XDG_STATE_HOME=$work/state XDG_DATA_HOME=$work/data XDG_CONFIG_HOME=$work/config
fails=0
commit() { git -C "$repo" -c user.name=t -c user.email=t@t commit -q "$@"; }

# A repo whose check-fast reports every line containing BAD in the files changed
# since $CHECK_BASE, breaks when a file named BROKEN exists and notes a skip when
# one named NOTE does
repo=$work/repo
git init -q "$repo"
commit --allow-empty -m init
mkdir "$repo/scripts"
cat >"$repo/scripts/check-fast" <<'EOF'
#!/usr/bin/env bash
cd "$(git rev-parse --show-toplevel)"
[[ -e BROKEN ]] && { echo "tool missing" >&2; exit 3; }
[[ -e NOTE ]] && echo "check-fast: part skipped" >&2
{ git diff --name-only "${CHECK_BASE:-HEAD}"; git ls-files --others --exclude-standard; } | sort -u |
  while IFS= read -r f; do [[ -f $f ]] && grep -n -H BAD "$f" | sed 's/:\([0-9]*\):.*/:\1: no-bad: remove BAD/'; done |
  grep . && exit 1
exit 0
EOF
chmod +x "$repo/scripts/check-fast"
git -C "$repo" add scripts
commit -m contract

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

absent() { # absent NAME TEXT OUTPUT
  if [[ $3 == *"$2"* ]]; then
    echo "FAIL $1: found \"$2\" in: $3"
    fails=$((fails + 1))
  else
    echo "ok   $1"
  fi
}

expect "outside a repo is silent" "" "$(hook "$work")"
mkdir "$work/plain" && git init -q "$work/plain"
expect "repo without check-fast is silent" "" "$(hook "$work/plain")"
echo BAD >"$repo/a.txt"
expect "a clone that hasn't opted in is silent" "" "$(hook "$repo")"
expect "run says how to opt in" 'not enabled.*agent-check\.enabled' "$("$ac" run "$repo")"
rm "$repo/a.txt"
git -C "$repo" config agent-check.enabled true
expect "clean tree is silent" "" "$(hook "$repo")"

echo good >"$repo/a.txt"
expect "passing check is silent" "" "$(hook "$repo")"

echo BAD >>"$repo/a.txt"
out=$(hook "$repo")
expect "findings block" '"decision": "block"' "$out"
expect "block names the finding" 'a\.txt:2: no-bad' "$out"
expect "block asks for a dropped question again" 'ask it again at the end' "$out"
expect "same findings again give up" 'turn ended with check-fast findings still open' "$(hook "$repo")"
expect "a settled state is silent" "" "$(hook "$repo")"
expect "another session gets its own block" '"decision": "block"' "$(hook "$repo" s2)"

echo BAD >"$repo/b.txt"
expect "new findings block again" '"decision": "block"' "$(hook "$repo")"
echo good >"$repo/a.txt" && rm "$repo/b.txt"
expect "fixed tree passes silently" "" "$(hook "$repo")"

# Committed work: check from where HEAD was at the last check
git -C "$repo" add a.txt && commit -m "a"
expect "a clean stop is silent" "" "$(hook "$repo")"
echo BAD >"$repo/d.txt" && git -C "$repo" add d.txt && commit -m "d"
out=$(hook "$repo")
expect "work committed in the turn is checked" '"decision": "block".*d\.txt:1: no-bad' "$out"
echo good >"$repo/d.txt" && commit -am "fix d"
expect "a committed fix passes silently" "" "$(hook "$repo")"
for i in $(seq 11); do commit --allow-empty -m "pulled $i"; done
echo BAD >"$repo/e.txt" && git -C "$repo" add e.txt && commit -m "pulled e"
expect "a pull's commits aren't the session's" "" "$(hook "$repo")"

touch "$repo/BROKEN"
out=$(hook "$repo")
expect "broken check doesn't block" '^\{[^}]*"systemMessage"' "$out"
expect "broken check says so" 'broken \(exit 3\).*tool missing' "$out"
rm "$repo/BROKEN"

if command -v direnv >/dev/null; then
  echo 'export X=1' >"$repo/.envrc"
  out=$(hook "$repo")
  expect "a blocked .envrc in an opted-in repo is allowed" 'a note from check-fast.*allowed .*/\.envrc' "$out"
  expect "and the check runs" '^\{[^}]*"systemMessage"[^}]*\}$' "$out"
  rm "$repo/.envrc"
fi

touch "$repo/NOTE"
out=$(hook "$repo")
expect "a pass with a note tells the person" '^\{[^}]*"systemMessage".*a note from check-fast.*part skipped' "$out"
echo again >>"$repo/a.txt"
expect "the same note isn't repeated" "" "$(hook "$repo")"
rm "$repo/NOTE"

git init -q "$repo/nested"
ln -s "$work/missing" "$repo/dangling"
rc=0 && out=$(hook "$repo") || rc=$?
expect "a nested clone and a dangling link don't break the hook" '^0$' "$rc"
rm -rf "$repo/nested" "$repo/dangling"

printf 'x=1 # shellcheck disable=SC2034\n' >"$repo/c.sh"
printf 'module x\n\ngo 1.26\n\nrequire example.com/dep v1.2.3\n' >"$repo/go.mod"
printf '{\n  "name": "x",\n  "version": "1.0.0",\n  "dependencies": {\n    "left-pad": "^1.3.0"\n  }\n}\n' >"$repo/package.json"
out=$(hook "$repo")
expect "added suppression is flagged" 'c\.sh:1: suppression' "$out"
expect "a go dependency is named" 'go\.mod:5: dependency: adds example\.com/dep v1\.2\.3' "$out"
expect "an npm dependency is named" 'package\.json:5: dependency: adds left-pad' "$out"
absent "a package's own version isn't a dependency" 'adds version' "$out"
expect "flags don't block" '^\{[^}]*"systemMessage"' "$out"
echo more >>"$repo/a.txt"
expect "unchanged flags aren't repeated" "" "$(hook "$repo")"
rm "$repo/c.sh" "$repo/go.mod" "$repo/package.json"

printf '[extend]\nuseDefault = true\n' >"$repo/.gitleaks.toml"
expect "a check config change is flagged" '\.gitleaks\.toml:0: check-config' "$(hook "$repo")"
rm "$repo/.gitleaks.toml"

out=$("$ac" run "$repo") || true
expect "run reports pass with a file count" 'check-fast \(repo\): pass \(1 files\)' "$out"
echo BAD >>"$repo/a.txt"
rc=0 && out=$("$ac" run "$repo") || rc=$?
expect "run reports findings" 'findings.*a\.txt:[0-9]+: no-bad' "$out"
expect "run exits 1 on findings" '^1$' "$rc"
git -C "$repo" checkout -q -- a.txt
expect "run on a clean tree has nothing to check" 'nothing to check' "$("$ac" run "$repo")"
rc=0 && out=$("$ac" run "$repo" HEAD~1) || rc=$?
expect "run from a base checks the commits since" 'findings.*e\.txt:1: no-bad' "$out"
expect "run without check-fast says none" 'none' "$("$ac" run "$work/plain")"

expect "each check is logged" 'repo.*block.*' "$(cat "$XDG_STATE_HOME/agent-check/log")"

if ((fails > 0)); then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
