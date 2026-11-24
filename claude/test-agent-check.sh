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
  expect "a blocked .envrc in an opted-in repo is allowed" 'a note from the checks.*allowed .*/\.envrc' "$out"
  expect "and the check runs" '^\{[^}]*"systemMessage"[^}]*\}$' "$out"
  rm "$repo/.envrc"
fi

touch "$repo/NOTE"
out=$(hook "$repo")
expect "a pass with a note tells the person" '^\{[^}]*"systemMessage".*a note from the checks.*part skipped' "$out"
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

# ---------------------------------------------------------------------------------------------------------------
# The default checks: tiers, modes, formatting (needs biome and gitleaks on PATH, as the installed agent-check has)
st=$XDG_STATE_HOME/agent-check
tcommit() { git -C "$1" -c user.name=t -c user.email=t@t commit -q "${@:2}"; }
hookj() { # hookj JSON-OBJECT-EXPRESSION: a Stop hook input built with jq
  jq -n "$1" | "$ac" hook
}

ts=$work/tsrepo
git init -q "$ts"
git -C "$ts" remote add origin https://github.com/dvmrry/tsrepo.git
printf '{\n  "formatter": { "indentStyle": "space", "indentWidth": 2 }\n}\n' >"$ts/biome.json"
printf 'export const ok = 1;\n' >"$ts/a.ts"
printf 'export function legacy( x:number ){ return x }\n' >"$ts/c.ts"
git -C "$ts" add -A && tcommit "$ts" -m init

printf 'export const ok = 1;\nexport function f() {\n  const unused = 2;\n  return ok;\n}\n' >"$ts/a.ts"
expect "a listed origin gets tier 0, and its findings start observed (silent)" "" "$(hook "$ts")"
expect "an observed finding is logged with its mode" '"mode":"observe","rule":"ts/biome-noUnusedVariables","path":"a.ts","line":3' "$(cat "$st/findings.jsonl")"
expect "run shows the observed count" 'checks \(tsrepo, tier 0\): pass.*observed only.*: [1-9]' "$("$ac" run "$ts")"

printf 'ts block\n* observe\n' >"$work/modes-block"
export AGENT_CHECK_MODES=$work/modes-block
out=$(hook "$ts" s3)
expect "a module in block mode sends its findings back" '"decision": "block".*agent-check found problems in your changes in tsrepo.*a\.ts:3: ts/biome-noUnusedVariables' "$out"

printf 'export function g( x:number ){ return x }\n' >"$ts/b.ts"
out=$(hook "$ts" s3)
expect "a new unformatted file is a finding" 'b\.ts:1: ts/format: not formatted; run agent-check fmt' "$out"
expect "the block says how to format" 'Formatting: run agent-check fmt' "$out"
printf 'export function legacy( x:number ){ return x }\n// touched\n' >"$ts/c.ts"
absent "a file unformatted at the base isn't this change's" 'c.ts:1: ts/format' "$out"
out=$(hook "$ts" s3)
absent "nor after an edit" 'c.ts:1: ts/format' "$out"
expect "fmt formats what the check reports" '^formatted b\.ts$' "$("$ac" fmt "$ts")"
expect "and leaves the legacy file alone" 'legacy\( x:number \)' "$(cat "$ts/c.ts")"
absent "a formatted file is clean" 'b.ts:1: ts/format' "$(hook "$ts" s4)"

tok=ghp_$(head -c 400 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 36)
printf 'token = "%s"\n' "$tok" >"$ts/creds.txt"
unset AGENT_CHECK_MODES
out=$(hook "$ts" s5)
expect "a secret blocks by default" '"decision": "block".*creds\.txt:1: common/gitleaks: github-pat looks like a secret' "$out"
absent "the secret itself isn't repeated" "$tok" "$out"
rm "$ts/creds.txt"

git -C "$ts" config agent-check.enabled false
expect "enabled=false turns a listed clone off" "" "$(hook "$ts" s6)"
git -C "$ts" config --unset agent-check.enabled

zs=$work/zrepo
git init -q "$zs"
git -C "$zs" remote add origin git@github.com:dvmrry/zscalerctl-dev.git
printf 'const unused = 1;\n' >"$zs/a.ts"
n0=$(wc -l <"$st/findings.jsonl")
expect "an excluded origin is silent" "" "$(hook "$zs")"
expect "and nothing is logged for it" "^$n0\$" "$(wc -l <"$st/findings.jsonl" | tr -d ' ')"

# Prompts, snapshots and checking every repo the prompt touched
sess="sess-aaaaaaaa"
jq -n --arg s $sess '{session_id: $s, prompt_id: "prompt-11111111", prompt: "fix the thing", hook_event_name: "UserPromptSubmit"}' | "$ac" prompt
expect "a prompt is recorded with its own chain" '"prompt_id":"prompt-11111111","chain":"prompt-11111111".*"prompt":"fix the thing"' "$(cat "$st/prompts/$sess.json")"
jq -n --arg s $sess '{session_id: $s, prompt_id: "prompt-22222222", prompt: "Stop hook feedback: agent-review chain=chain-abcdef12 found 1"}' | "$ac" prompt
expect "a review's rewake keeps its chain" '"prompt_id":"prompt-22222222","chain":"chain-abcdef12"' "$(cat "$st/prompts/$sess.json")"

sr=$work/snaprepo
git init -q "$sr"
cp -R "$repo/scripts" "$sr/"
echo good >"$sr/x.txt"
git -C "$sr" add -A && tcommit "$sr" -m init
git -C "$sr" config agent-check.enabled true
echo untracked >"$sr/u.txt"
jq -n --arg s $sess --arg f "$sr/x.txt" --arg cwd "$work" '{session_id: $s, prompt_id: "prompt-33333333", tool_name: "Edit", tool_input: {file_path: $f}, cwd: $cwd}' | "$ac" snap
marker=$(ls "$st/snaps/$sess/prompt-33333333/"*)
tree=$(cut -f2 "$marker")
expect "snap records the repo and a tree" "^$(cd "$sr" && pwd -P)	[0-9a-f]{40}\$" "$(cat "$marker")"
expect "the snapshot holds untracked files" 'u\.txt' "$(git -C "$sr" ls-tree -r --name-only "$tree")"
expect "and the real index is untouched" '^\?\? u\.txt$' "$(git -C "$sr" status --porcelain)"
mtime=$(stat -c %Y "$marker")
sleep 1
jq -n --arg s $sess --arg cwd "$sr" '{session_id: $s, prompt_id: "prompt-33333333", tool_name: "Bash", tool_input: {command: "ls"}, cwd: $cwd}' | "$ac" snap
expect "a second touch in the same prompt doesn't snapshot again" "^$mtime\$" "$(stat -c %Y "$marker")"
echo BAD >"$sr/x.txt"
out=$(hookj "{cwd: \"$work\", session_id: \"$sess\", prompt_id: \"prompt-33333333\"}")
expect "a stop checks the repos its prompt touched, wherever the session is" '"decision": "block".*in snaprepo.*x\.txt:1: no-bad' "$out"

echo good >"$sr/x.txt"
expect "fixed, it settles" "" "$(hookj "{cwd: \"$sr\", session_id: \"$sess\", prompt_id: \"prompt-33333333\"}")"

# One prompt's turn is sent back a limited number of times, across stops (each time with new findings, so
# agent-check's own same-findings rule doesn't end it first)
jq -n --arg s $sess '{session_id: $s, prompt_id: "prompt-44444444", prompt: "go"}' | "$ac" prompt
p4() { AGENT_CHECK_MAX_CONTINUATIONS=2 hookj "{cwd: \"$sr\", session_id: \"$sess\", prompt_id: \"prompt-44444444\"}"; }
printf 'BAD\n' >"$sr/x.txt"
expect "first send-back" '"decision": "block"' "$(p4)"
printf 'ok\nBAD\n' >"$sr/x.txt"
expect "second send-back" '"decision": "block"' "$(p4)"
printf 'ok\nok\nBAD\n' >"$sr/x.txt"
out=$(p4)
expect "past the cap the person is told instead" '^\{[^}]*"systemMessage".*already sent back 2 times' "$out"
absent "and the model isn't" '"decision"' "$out"
echo good >"$sr/x.txt"

# Background work: tier 1 (here, the repo's check-fast) is skipped
echo BAD >"$sr/y.txt"
out=$(hookj "{cwd: \"$sr\", session_id: \"sess-busy0000\", background_tasks: [{id: \"a\", type: \"agent\", status: \"running\"}]}")
absent "tier 1 waits while background tasks run" '"decision"' "$out"
expect "and the log says why" 'snaprepo.*background tasks running' "$(tail -1 "$st/log")"
out=$(hookj "{cwd: \"$sr\", session_id: \"sess-busy0001\", background_tasks: [{id: \"a\", type: \"agent\", status: \"completed\"}]}")
expect "finished background tasks don't count" '"decision": "block".*y\.txt:1: no-bad' "$out"
rm "$sr/y.txt"

git -C "$sr" config agent-check.exclude 'x.txt'
echo more >>"$sr/u.txt"
expect "a change to the clone's own settings is flagged" 'check-config: this clone.s agent-check settings changed' "$(hook "$sr" s9)"

# Replay: what each rule would have reported on history
printf 'export function h() {\n  const spare = 3;\n  return 1;\n}\n' >"$ts/d.ts"
git -C "$ts" add d.ts && tcommit "$ts" -m "d"
expect "replay sums up a rule over history" 'ts/biome-noUnusedVariables +observe +1 +1 +d\.ts:2' "$("$ac" replay "$ts" 5)"
expect "and cleans up its worktrees" '^1$' "$(git -C "$ts" worktree list | wc -l | tr -d ' ')"

if ((fails > 0)); then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
