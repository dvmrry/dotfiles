#!/usr/bin/env bash
# agent-check: run a repo's scripts/check-fast over an agent's uncommitted work.
#
#   agent-check hook        Claude Code Stop hook (reads the hook's JSON on stdin)
#   agent-check run [DIR]   plain report, for scripts that dispatch workers
#
# The checks live in each repo. An executable scripts/check-fast checks what
# changed since $CHECK_BASE (default HEAD), untracked files included: lint
# findings in the changed files (only on the lines a change adds, where a file
# has old ones) and build errors wherever they land. It prints findings as
# `path:line: rule: message` and exits 0 (clean), 1 (findings) or anything else
# (the check itself is broken: a missing tool, a crash). Its stderr is a note
# for the person, such as a part it skipped. Repos without one are skipped, so
# elsewhere the hook costs one `git rev-parse`.
#
# agent-check also flags what only the orchestrator should decide: suppressions
# added in the diff, changes to the checks' own configuration (scripts/check-fast,
# the flake, allowlists, lint configs) and changed dependency manifests. Flags
# and notes go to the person (hook) or the orchestrator (run), once each, and
# never block.
set -euo pipefail

max_lines=20 # findings shown; the rest become "... and N more"
max_blocks=3 # times one stretch of failures may send the model back
check_timeout=${AGENT_CHECK_TIMEOUT:-45}
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/agent-check

suppression_re='nolint|lint:ignore|shellcheck disable|eslint-disable|biome-ignore|swiftlint:disable|periphery:ignore|noqa|type: ?ignore|@ts-ignore|@ts-expect-error|#\[allow\('
check_config_re='(^|/)(scripts/check-fast|flake\.nix|\.envrc|\.gitleaks\.toml|\.gitleaksignore|\.shellcheckrc|\.golangci\.ya?ml|\.swiftlint\.ya?ml|\.swift-format|\.swiftformat|\.periphery\.ya?ml|biome\.jsonc?|eslint\.config\.[a-z]+|\.eslintrc[^/]*|ruff\.toml|\.semgrepignore|[^/]*allowlist[^/]*)$'
manifest_re='(^|/)(go\.mod|package\.json|Cargo\.toml|Package\.swift|pubspec\.yaml|requirements[^/]*\.txt|pyproject\.toml)$'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cap() {
  awk -v max="$max_lines" 'NR <= max; END { if (NR > max) printf "... and %d more\n", NR - max }' "$1"
}

# tree_state ROOT: a hash of HEAD, the uncommitted diff and the untracked
# files; nothing when the tree is clean (commits are prek's and CI's job).
tree_state() {
  local root=$1
  [[ -n $(git -C "$root" status --porcelain --untracked-files=all) ]] || return 0
  {
    git -C "$root" rev-parse -q --verify HEAD || true
    git -C "$root" diff HEAD --binary 2>/dev/null || true
    git -C "$root" ls-files -z --others --exclude-standard |
      (cd "$root" && xargs -0 sha256sum --)
  } | sha256sum | cut -c1-16
}

# run_contract ROOT: runs scripts/check-fast inside the repo's direnv
# environment when it has one, since agent shells don't load direnv. Sets rc;
# output lands in $tmp/out and $tmp/err.
run_contract() {
  local root=$1
  local -a cmd=("$root/scripts/check-fast")
  if [[ -f $root/.envrc ]] && command -v direnv >/dev/null; then
    cmd=(direnv exec "$root" "${cmd[@]}")
  fi
  rc=0
  (cd "$root" && timeout "$check_timeout" "${cmd[@]}") >"$tmp/out" 2>"$tmp/err" || rc=$?
  if ((rc == 1)) && [[ ! -s $tmp/out ]]; then
    rc=2 # findings with nothing printed: the check failed, not the code
  fi
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

# flags ROOT: suppressions added, check configuration and dependency manifests
# changed since $CHECK_BASE, as `path:line: flag: message`.
flags() {
  local root=$1 base=${CHECK_BASE:-HEAD}
  # Lines added to tracked files, as path:line:text
  git -C "$root" diff -U0 --no-color "$base" -- 2>/dev/null | awk '
		/^\+\+\+ b\// { file = substr($0, 7); next }
		/^\+\+\+ /    { file = ""; next }
		/^@@/         { split($3, a, ","); line = substr(a[1], 2) + 0; next }
		/^\+/ && file { print file ":" line ":" substr($0, 2); line++ }
	' >"$tmp/added" || true
  git -C "$root" ls-files -z --others --exclude-standard >"$tmp/untracked"
  {
    grep -E -- "^[^:]+:[0-9]+:.*($suppression_re)" "$tmp/added" | cut -d: -f1,2 || true
    (cd "$root" && xargs -0 grep -n -H -I -E -- "$suppression_re" <"$tmp/untracked" | cut -d: -f1,2) || true
  } | sort -u | sed 's/$/: suppression: added; whether it stays is the orchestrator'"'"'s call/'
  # Every file touched, deletions included
  {
    git -C "$root" diff --name-only "$base" -- 2>/dev/null || true
    tr '\0' '\n' <"$tmp/untracked"
  } | sort -u >"$tmp/touched"
  { grep -E -- "$check_config_re" "$tmp/touched" || true; } |
    sed 's/$/:0: check-config: changed; it decides what the checks report, so it'"'"'s the orchestrator'"'"'s call/'
  { grep -E -- "$manifest_re" "$tmp/touched" || true; } |
    sed 's/$/:0: dependency: manifest changed; new dependencies are the orchestrator'"'"'s call/'
}

json_system() {
  jq -n --arg m "$1" '{systemMessage: $m}'
}

hook() {
  local input cwd session root state
  input=$(cat)
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  session=$(jq -r '.session_id // "none"' <<<"$input")
  root=$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || return 0
  [[ -x $root/scripts/check-fast ]] || return 0
  state=$(tree_state "$root")
  [[ -n $state ]] || return 0

  # Per repo and session: the last tree state settled (passed, given up on or
  # broken), the last findings hash, blocks spent since, and the hashes of the
  # flags and the note last shown
  local sf settled=- last_findings=- blocks=0 last_flags=- last_note=-
  mkdir -p "$state_dir"
  sf=$state_dir/$(printf '%s\n' "$root" "$session" | sha256sum | cut -c1-16)
  if [[ -f $sf ]]; then
    read -r settled last_findings blocks last_flags last_note <"$sf"
  fi
  if [[ $state == "$settled" ]]; then
    return 0
  fi

  run_contract "$root"
  local name=${root##*/} note="" fl=- nh=- said
  flags "$root" >"$tmp/flags"
  if [[ -s $tmp/flags ]]; then
    fl=$(sha256sum <"$tmp/flags" | cut -c1-16)
    if [[ $fl != "$last_flags" ]]; then
      note="agent-check ($name), for you to decide:"$'\n'$(cap "$tmp/flags")
    fi
  fi
  # On a pass or findings, stderr is the check's note (a broken check's is
  # its error, shown below)
  said=""
  if ((rc <= 1)); then
    said=$(errors 3)
  fi
  if [[ -n $said ]]; then
    nh=$(sha256sum <<<"$said" | cut -c1-16)
    if [[ $nh != "$last_note" ]]; then
      note="agent-check ($name), a note from check-fast:"$'\n'$said${note:+$'\n'$note}
    fi
  fi

  if ((rc == 1)); then
    local fh
    fh=$(sha256sum <"$tmp/out" | cut -c1-16)
    if [[ $fh == "$last_findings" ]] || ((blocks >= max_blocks)); then
      # The model was told and didn't (or couldn't) fix it: tell the person
      printf '%s %s 0 %s %s\n' "$state" "$fh" "$fl" "$nh" >"$sf"
      note="agent-check ($name): the turn ended with check-fast findings still open:"$'\n'$(cap "$tmp/out")${note:+$'\n'$note}
      json_system "$note"
      return 0
    fi
    printf '%s %s %d %s %s\n' "$settled" "$fh" $((blocks + 1)) "$fl" "$nh" >"$sf"
    jq -n --arg r "scripts/check-fast found problems in your uncommitted changes in $name:
$(cap "$tmp/out")
Fix them before you finish. If one is wrong, say why in your reply instead of adding a suppression. Re-check with: scripts/check-fast" \
      --arg m "$note" '{decision: "block", reason: $r} + (if $m == "" then {} else {systemMessage: $m} end)'
    return 0
  fi

  if ((rc != 0)); then
    # A broken check tells the person and never blocks
    note="agent-check ($name): scripts/check-fast is broken (exit $rc), so nothing was checked:"$'\n'$(errors 3)${note:+$'\n'$note}
  fi
  printf '%s - 0 %s %s\n' "$state" "$fl" "$nh" >"$sf"
  if [[ -n $note ]]; then
    json_system "$note"
  fi
}

run() {
  local root
  root=$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null) || {
    echo "agent-check: ${1:-.} is not in a git repo" >&2
    return 2
  }
  local name=${root##*/} status=0
  if [[ ! -x $root/scripts/check-fast ]]; then
    echo "check-fast ($name): none"
    return 0
  fi
  run_contract "$root"
  case $rc in
    0) echo "check-fast ($name): pass" ;;
    1)
      echo "check-fast ($name): findings"
      cap "$tmp/out"
      status=1
      ;;
    *)
      echo "check-fast ($name): broken (exit $rc)"
      errors 5
      status=2
      ;;
  esac
  if ((rc <= 1)) && [[ -n $(errors 1) ]]; then
    echo "notes:"
    errors 5
  fi
  flags "$root" >"$tmp/flags"
  if [[ -s $tmp/flags ]]; then
    echo "flags (the orchestrator's call):"
    cap "$tmp/flags"
  fi
  return "$status"
}

case ${1:-} in
  hook) hook ;;
  run)
    shift
    run "$@"
    ;;
  *)
    echo "usage: agent-check hook | agent-check run [DIR]" >&2
    exit 2
    ;;
esac
