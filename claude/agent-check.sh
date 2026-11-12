#!/usr/bin/env bash
# agent-check: run a repo's scripts/check-fast over an agent's work.
#
#   agent-check hook              Claude Code Stop hook (reads the hook's JSON on stdin)
#   agent-check run [DIR [BASE]]  the same check as a plain report: for scripts that
#                                 dispatch workers, and for re-checking by hand
#
# A repo opts in per clone, so a cloned repo's script never runs by surprise
# (its worktrees share the setting):  git config agent-check.enabled true
#
# The checks live in the repo. An executable scripts/check-fast checks what
# changed since $CHECK_BASE (default HEAD), untracked files included: lint
# findings in the changed files (only on the lines a change adds, where a file
# has old ones) and build errors wherever they land. An incremental compiler
# repeats warnings only for files it compiles, and the agent may have built
# already, so make it compile the changed files (dtv touches them; go vet
# reruns a failing package on its own). It prints findings as
# `path:line: rule: message` and exits 0 (clean), 1 (findings) or anything else
# (the check itself is broken: a missing tool, a crash). Its stderr is a note
# for the person, such as a part it skipped. The hook sets $CHECK_BASE to where
# HEAD was at the session's last check, so work committed in a turn is checked.
#
# agent-check also flags what only the orchestrator should decide: suppressions
# added, changes to the checks' own configuration (scripts/check-fast, the
# flake, allowlists, lint configs) and dependencies added. Flags and notes go to
# the person (hook) or the orchestrator (run), once each, and never block. Each
# check is logged, one line, to ~/.local/state/agent-check/log.
set -euo pipefail

max_lines=20   # findings shown; the rest become "... and N more"
max_blocks=3   # times one stretch of failures may send the model back
max_commits=10 # more commits since the last check than this came from elsewhere (a pull)
check_timeout=${AGENT_CHECK_TIMEOUT:-45}
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/agent-check

suppression_re='nolint|lint:ignore|shellcheck disable|eslint-disable|biome-ignore|swiftlint:disable|periphery:ignore|gitleaks:allow|@ts-ignore|@ts-expect-error|#\[allow\('
check_config_re='(^|/)(scripts/check-fast|flake\.nix|\.envrc|\.gitleaks\.toml|\.gitleaksignore|\.shellcheckrc|\.golangci\.ya?ml|\.swiftlint\.ya?ml|\.swift-format|\.swiftformat|\.periphery\.ya?ml|biome\.jsonc?|eslint\.config\.[a-z]+|\.eslintrc[^/]*|ruff\.toml|\.semgrepignore|[^/]*allowlist[^/]*)$'
manifest_re='(^|/)(go\.mod|Package\.swift|package\.json|pubspec\.yaml|requirements[^/]*\.txt)$'

# `git diff -U0` to the lines it adds, as path:line:text
read -r -d '' added_awk <<'EOF' || true
/^\+\+\+ b\// { file = substr($0, 7); next }
/^\+\+\+ /    { file = ""; next }
/^@@/         { split($3, a, ","); line = substr(a[1], 2) + 0; next }
/^\+/ && file { print file ":" line ":" substr($0, 2); line++ }
EOF

# Added path:line:text lines to the dependencies they add, by manifest
read -r -d '' deps_awk <<'EOF' || true
{
  path = $0; sub(/:.*/, "", path)
  rest = substr($0, length(path) + 2); line = rest; sub(/:.*/, "", line)
  text = substr(rest, length(line) + 2)
  dep = ""
  if (path ~ /(^|\/)go\.mod$/) {
    if (match(text, /[a-z0-9.-]+\.[a-z]+\/[^ \t]+[ \t]+v[0-9][^ \t]*/)) dep = substr(text, RSTART, RLENGTH)
  } else if (path ~ /(^|\/)Package\.swift$/) {
    if (match(text, /\.package\([^)]*(url|path): *"[^"]+"/)) {
      dep = substr(text, RSTART, RLENGTH); sub(/^.*: *"/, "", dep); sub(/"$/, "", dep)
    }
  } else if (path ~ /(^|\/)package\.json$/) {
    if (text !~ /"(version|name|main|types|module|node|npm|bun|pnpm|yarn)" *:/ &&
        match(text, /"[@a-z0-9][a-z0-9._\/-]*" *: *"(\^|~|>|=|[0-9]|\*|latest|npm:|workspace:|github:|git|https?:|file:|link:)/)) {
      dep = substr(text, RSTART, RLENGTH); sub(/^"/, "", dep); sub(/".*/, "", dep)
    }
  } else if (path ~ /(^|\/)pubspec\.yaml$/) {
    if (text !~ /^  (sdk|flutter):/ && match(text, /^  [a-z0-9_]+: *(\^|>|[0-9]|any)/)) {
      dep = text; sub(/^ +/, "", dep); sub(/:.*/, "", dep)
    }
  } else if (path ~ /(^|\/)requirements[^\/]*\.txt$/) {
    if (text !~ /^[ \t]*(#|-|$)/) dep = text
  }
  if (dep != "") printf "%s:%s: dependency: adds %s; new dependencies are the orchestrator's call\n", path, line, dep
}
EOF

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cap() {
  awk -v max="$max_lines" 'NR <= max; END { if (NR > max) printf "... and %d more\n", NR - max }' "$1"
}

# enabled ROOT: the repo has a check and this clone opted in
enabled() {
  [[ -x $1/scripts/check-fast && $(git -C "$1" config --bool agent-check.enabled 2>/dev/null) == true ]]
}

# session_base ROOT PREV: PREV (HEAD at the last check) when the commits since
# look like the session's own (it's an ancestor, and they're few), else HEAD
session_base() {
  local root=$1 prev=$2 n
  if [[ $prev != - ]] && git -C "$root" merge-base --is-ancestor "$prev" HEAD 2>/dev/null; then
    n=$(git -C "$root" rev-list --count "$prev..HEAD")
    if ((n > 0 && n <= max_commits)); then
      echo "$prev"
      return
    fi
  fi
  echo HEAD
}

# changed_files ROOT BASE: the files there are to check
changed_files() {
  local root=$1 base=$2 f
  {
    git -C "$root" diff --name-only "$base" -- 2>/dev/null || true
    git -C "$root" ls-files --others --exclude-standard
  } | sort -u | while IFS= read -r f; do
    if [[ -f $root/$f ]]; then echo "$f"; fi
  done
}

# tree_state ROOT BASE: a hash of what there is to check (the diff from BASE
# and the untracked files), or nothing when there's nothing
tree_state() {
  local root=$1 base=$2
  if [[ $base == HEAD && -z $(git -C "$root" status --porcelain --untracked-files=all) ]]; then
    return 0
  fi
  git -C "$root" ls-files -z --others --exclude-standard >"$tmp/untracked.z"
  {
    git -C "$root" rev-parse -q --verify HEAD || true
    echo "$base"
    git -C "$root" diff "$base" --binary 2>/dev/null || true
    cat "$tmp/untracked.z"
    # A nested clone or a dangling link can't be read; its name still counts
    (cd "$root" && xargs -0 sha256sum -- <"$tmp/untracked.z" 2>/dev/null) || true
  } | sha256sum | cut -c1-16
}

# run_contract ROOT BASE: runs scripts/check-fast inside the repo's direnv
# environment when it has one, since agent shells don't load direnv. Sets rc,
# secs and allowed; output lands in $tmp/out and $tmp/err.
run_contract() {
  local root=$1 base=$2 t0=$EPOCHREALTIME try
  local -a cmd=("$root/scripts/check-fast")
  if [[ -f $root/.envrc ]] && command -v direnv >/dev/null; then
    cmd=(direnv exec "$root" "${cmd[@]}")
  fi
  allowed=""
  for try in 1 2; do
    rc=0
    (cd "$root" && CHECK_BASE=$base timeout "$check_timeout" "${cmd[@]}") >"$tmp/out" 2>"$tmp/err" || rc=$?
    # direnv trusts a path, not a repo, so a new worktree's .envrc starts out
    # blocked; the repo opted in, so allow it and run again
    if ((try == 1 && rc != 0)) && grep -q 'is blocked' "$tmp/err" && direnv allow "$root" 2>/dev/null; then
      allowed="allowed $root/.envrc for direnv (the repo opted in)"
      continue
    fi
    break
  done
  if ((rc == 1)) && [[ ! -s $tmp/out ]]; then
    rc=2 # findings with nothing printed: the check failed, not the code
  fi
  secs=$(awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.1f", b - a }')
}

# errors N: the first N lines of the check's stderr, minus colour codes,
# direnv's and nix-direnv's progress lines (their errors, like a blocked .envrc,
# stay) and nix's dirty-tree warning
errors() {
  sed 's/\x1b\[[0-9;]*m//g' "$tmp/err" | awk '
    /^(nix-)?direnv: / && !/error|blocked/ { next }
    /^warning: Git tree .* is dirty$/ { next }
    { print }' | head -"$1"
}

# notes: what the person should hear about this run besides findings and flags
notes() {
  if [[ -n $allowed ]]; then echo "agent-check: $allowed"; fi
  if ((rc <= 1)); then errors 3; fi
}

# flags ROOT BASE: suppressions added, check configuration changed and
# dependencies added since BASE, as `path:line: flag: message`
flags() {
  local root=$1 base=$2 f
  git -C "$root" diff -U0 --no-color "$base" -- 2>/dev/null | awk "$added_awk" >"$tmp/added" || true
  git -C "$root" ls-files -z --others --exclude-standard >"$tmp/untracked.z"
  # An untracked manifest is wholly added
  tr '\0' '\n' <"$tmp/untracked.z" | { grep -E -- "$manifest_re" || true; } |
    while IFS= read -r f; do (cd "$root" && grep -n -H -I -s -- '' "$f") || true; done >>"$tmp/added"
  {
    grep -E -- "^[^:]+:[0-9]+:.*($suppression_re)" "$tmp/added" | cut -d: -f1,2 || true
    (cd "$root" && xargs -0 grep -n -H -I -s -E -- "$suppression_re" <"$tmp/untracked.z" | cut -d: -f1,2) || true
  } | sort -u | sed 's/$/: suppression: added; whether it stays is the orchestrator'"'"'s call/'
  # Every file touched, deletions included
  {
    git -C "$root" diff --name-only "$base" -- 2>/dev/null || true
    tr '\0' '\n' <"$tmp/untracked.z"
  } | sort -u | { grep -E -- "$check_config_re" || true; } |
    sed 's/$/:0: check-config: changed; it decides what the checks report, so it'"'"'s the orchestrator'"'"'s call/'
  awk "$deps_awk" "$tmp/added"
}

# log REPO SESSION BASE FILES OUTCOME NOTE: one line per check, for reading later
log() {
  local note=${6//$'\n'/ | }
  printf '%s\t%s\t%s\t%s\t%s files\t%s\t%ss\t%s\n' "$(date +%FT%T)" "$1" "${2:0:8}" "${3:0:12}" "$4" "$5" "$secs" "$note" >>"$state_dir/log"
}

hook() {
  local input cwd session root
  input=$(cat)
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  session=$(jq -r '.session_id // "none"' <<<"$input")
  root=$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || return 0
  enabled "$root" || return 0

  # Per repo and session: the last tree state settled (passed, given up on or
  # broken), the last findings hash, blocks spent since, the hashes of the flags
  # and the note last shown, and HEAD at the last settle
  local sf settled=- last_findings=- blocks=0 last_flags=- last_note=- prev_head=-
  mkdir -p "$state_dir"
  sf=$state_dir/$(printf '%s\n' "$root" "$session" | sha256sum | cut -c1-16)
  if [[ -f $sf ]]; then
    read -r settled last_findings blocks last_flags last_note prev_head <"$sf"
  fi
  local head base state
  head=$(git -C "$root" rev-parse -q --verify HEAD || echo -)
  base=$(session_base "$root" "${prev_head:--}")
  state=$(tree_state "$root" "$base")
  if [[ -z $state ]]; then
    # Nothing to check, but later commits count from here
    printf '%s %s %s %s %s %s\n' "$settled" "$last_findings" "$blocks" "$last_flags" "${last_note:--}" "$head" >"$sf"
    return 0
  fi
  if [[ $state == "$settled" ]]; then
    return 0
  fi

  local name=${root##*/} files note="" fl=- nh=- said
  files=$(changed_files "$root" "$base" | wc -l | tr -d ' ')
  run_contract "$root" "$base"
  flags "$root" "$base" >"$tmp/flags"
  if [[ -s $tmp/flags ]]; then
    fl=$(sha256sum <"$tmp/flags" | cut -c1-16)
    if [[ $fl != "$last_flags" ]]; then
      note="agent-check ($name), for you to decide:"$'\n'$(cap "$tmp/flags")
    fi
  fi
  said=$(notes)
  if [[ -n $said ]]; then
    nh=$(sha256sum <<<"$said" | cut -c1-16)
    if [[ $nh != "${last_note:--}" ]]; then
      note="agent-check ($name), a note from check-fast:"$'\n'$said${note:+$'\n'$note}
    fi
  fi

  if ((rc == 1)); then
    local fh
    fh=$(sha256sum <"$tmp/out" | cut -c1-16)
    if [[ $fh == "$last_findings" ]] || ((blocks >= max_blocks)); then
      # The model was told and didn't (or couldn't) fix it: tell the person
      printf '%s %s 0 %s %s %s\n' "$state" "$fh" "$fl" "$nh" "$head" >"$sf"
      log "$name" "$session" "$base" "$files" gave-up "$(head -1 "$tmp/out")"
      note="agent-check ($name): the turn ended with check-fast findings still open:"$'\n'$(cap "$tmp/out")${note:+$'\n'$note}
      jq -n --arg m "$note" '{systemMessage: $m}'
      return 0
    fi
    # Not settled: the next stop still checks everything since the last settle
    printf '%s %s %d %s %s %s\n' "$settled" "$fh" $((blocks + 1)) "$fl" "$nh" "${prev_head:--}" >"$sf"
    log "$name" "$session" "$base" "$files" block "$(head -1 "$tmp/out")"
    jq -n --arg r "scripts/check-fast found problems in your changes in $name:
$(cap "$tmp/out")
Fix them before you finish. If one is wrong, say why in your reply instead of adding a suppression. If you had stopped to ask something, ask it again at the end. Re-check with: agent-check run" \
      --arg m "$note" '{decision: "block", reason: $r} + (if $m == "" then {} else {systemMessage: $m} end)'
    return 0
  fi

  local outcome=pass
  if ((rc != 0)); then
    # A broken check tells the person and never blocks
    outcome="broken($rc)"
    note="agent-check ($name): scripts/check-fast is broken (exit $rc), so nothing was checked:"$'\n'$(errors 3)${note:+$'\n'$note}
  fi
  printf '%s - 0 %s %s %s\n' "$state" "$fl" "$nh" "$head" >"$sf"
  log "$name" "$session" "$base" "$files" "$outcome" "$said"
  if [[ -n $note ]]; then
    jq -n --arg m "$note" '{systemMessage: $m}'
  fi
}

run() {
  local root
  root=$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null) || {
    echo "agent-check: ${1:-.} is not in a git repo" >&2
    return 2
  }
  local name=${root##*/} base=${2:-${CHECK_BASE:-HEAD}} files status=0 outcome said
  if ! enabled "$root"; then
    if [[ -x $root/scripts/check-fast ]]; then
      echo "check-fast ($name): not enabled in this clone (git config agent-check.enabled true)"
    else
      echo "check-fast ($name): none"
    fi
    return 0
  fi
  files=$(changed_files "$root" "$base" | wc -l | tr -d ' ')
  if ((files == 0)); then
    echo "check-fast ($name): nothing to check (no changes since $base)"
    return 0
  fi
  run_contract "$root" "$base"
  case $rc in
    0)
      outcome=pass
      echo "check-fast ($name): pass ($files files)"
      ;;
    1)
      outcome=findings
      echo "check-fast ($name): findings ($files files)"
      cap "$tmp/out"
      status=1
      ;;
    *)
      outcome="broken($rc)"
      echo "check-fast ($name): broken (exit $rc)"
      errors 5
      status=2
      ;;
  esac
  said=$(notes)
  if [[ -n $said ]]; then
    echo "notes:"
    echo "$said"
  fi
  flags "$root" "$base" >"$tmp/flags"
  if [[ -s $tmp/flags ]]; then
    echo "flags (the orchestrator's call):"
    cap "$tmp/flags"
  fi
  mkdir -p "$state_dir"
  log "$name" run "$base" "$files" "$outcome" "$said"
  return "$status"
}

case ${1:-} in
  hook) hook ;;
  run)
    shift
    run "$@"
    ;;
  *)
    echo "usage: agent-check hook | agent-check run [DIR [BASE]]" >&2
    exit 2
    ;;
esac
