#!/usr/bin/env bash
# agent-check: checks an agent's work when its turn ends.
#
#   agent-check hook              Claude Code Stop hook (reads the hook's JSON on stdin)
#   agent-check prompt            UserPromptSubmit hook: records the prompt and starts its chain of continuations
#   agent-check snap              PreToolUse hook (Edit|Write|NotebookEdit|Bash): snapshots a repo's working tree
#                                 the first time a prompt touches it, so the stop checks every repo the turn
#                                 touched, and the turn's own changes can be told from what was there before
#   agent-check run [DIR [BASE]]  the same check as a plain report: for scripts that dispatch workers, and for
#                                 re-checking by hand
#   agent-check fmt [DIR [BASE]]  formats the changed files the checks report as unformatted
#   agent-check replay DIR [N] [--tier1]
#                                 runs the default checks over each of the last N commits (default 25) and sums
#                                 up what each rule would have reported: how a check earns `block` (see modes)
#
# What runs where:
# - A clone that opted in (git config agent-check.enabled true; its worktrees share the setting) gets tier 1: its
#   own scripts/check-fast, if it has one, and the default checks for the languages that script doesn't cover,
#   with builds, type checks, tests and the repo's own tools allowed. A check-fast says what it covers in a header
#   line, `# check-fast covers: ts sh json`; one without the line covers everything.
# - A clone whose origin check-default/tier0 lists gets the default checks at tier 0: static, with agent-check's
#   own pinned tools only, so nothing from the repo runs (a cloned repo's code never runs by surprise).
# - `git config agent-check.enabled false` turns a clone off, and AGENT_CHECK=off turns everything off.
# While the session has background tasks running (workers may be mid-edit), a stop runs tier 0 only.
#
# A repo's check-fast checks what changed since $CHECK_BASE (default HEAD), untracked files included: lint
# findings in the changed files (only on the lines a change adds, where a file has old ones) and build errors
# wherever they land. An incremental compiler repeats warnings only for files it compiles, and the agent may have
# built already, so make it compile the changed files (dtv touches them; go vet reruns a failing package on its
# own). It prints findings as `path:line: rule: message` and exits 0 (clean), 1 (findings) or anything else (the
# check itself is broken: a missing tool, a crash). Its stderr is a note for the person, such as a part it
# skipped. The hook sets $CHECK_BASE to where HEAD was at the session's last check, so work committed in a turn is
# checked.
#
# The default checks (check-default/) name their rules `language/rule`, and check-default/modes gives each a
# mode: block (sent to the model, as check-fast findings are), notify (told to the person) or observe (logged
# only). Every finding, whatever its mode, is logged to ~/.local/state/agent-check/findings.jsonl.
#
# agent-check also flags what only the orchestrator should decide: suppressions added, changes to the checks' own
# configuration (scripts/check-fast, the flake, allowlists, lint configs) and dependencies added. Flags and notes
# go to the person (hook) or the orchestrator (run), once each, and never block. Each check is logged, one line,
# to ~/.local/state/agent-check/log. One prompt's turn is sent back at most $max_continuations times, all checks
# and repos together.
set -euo pipefail
umask 077

max_lines=20                                          # findings shown; the rest become "... and N more"
max_blocks=3                                          # times one stretch of failures may send the model back
max_commits=10                                        # more commits since the last check than this came from elsewhere (a pull)
max_continuations=${AGENT_CHECK_MAX_CONTINUATIONS:-6} # per prompt, under Claude Code's own cap of 8
max_roots=6                                           # repos one stop checks
check_timeout=${AGENT_CHECK_TIMEOUT:-45}
budget=${AGENT_CHECK_BUDGET:-150} # seconds for all of a stop's checks, across repos
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/agent-check
lib_dir=${AGENT_CHECK_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-default}
modes_file=${AGENT_CHECK_MODES:-$lib_dir/modes}
deadline=$(($(date +%s) + budget))

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

# The mode of each finding line ("mode<TAB>line"), from the modes file: the most specific pattern wins
read -r -d '' modes_awk <<'EOF' || true
NR == FNR {
  if ($0 ~ /^[[:space:]]*(#|$)/) next
  n = split($0, a, /[[:space:]]+/); if (n >= 2) mode[a[1]] = a[2]
  next
}
{
  rule = $0; sub(/^[^:]+:[0-9]+: /, "", rule); sub(/: .*$/, "", rule)
  lang = rule; sub(/\/.*$/, "", lang)
  m = (rule in mode) ? mode[rule] : (lang in mode) ? mode[lang] : ("*" in mode) ? mode["*"] : "observe"
  print m "\t" $0
}
EOF

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cap() {
  awk -v max="$max_lines" 'NR <= max; END { if (NR > max) printf "... and %d more\n", NR - max }' "$1"
}

# left: seconds until the stop's deadline, at least 1
left() {
  local n=$((deadline - $(date +%s)))
  echo $((n > 0 ? n : 1))
}

# safe_id ID: a session or prompt id fit for a file name
safe_id() { [[ $1 =~ ^[A-Za-z0-9-]{8,80}$ ]]; }

# hash16 TEXT
hash16() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# origin_of ROOT: the clone's origin as host/owner/repo
origin_of() {
  local url
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
  url=${url%.git}
  url=${url#*://}
  url=${url#*@}
  echo "${url/://}"
}

# tier ROOT: 1 (opted in), 0 (its origin is listed in tier0) or - (not checked)
tier() {
  local root=$1 on origin kind pat ok=0
  on=$(git -C "$root" config --bool agent-check.enabled 2>/dev/null || true)
  if [[ $on == true ]]; then
    echo 1
    return
  fi
  if [[ $on != false ]] && origin=$(origin_of "$root"); then
    while read -r kind pat; do
      [[ $origin =~ $pat ]] || continue
      if [[ $kind == exclude ]]; then
        ok=0
        break
      fi
      if [[ $kind == include ]]; then ok=1; fi
    done < <(grep -v -E '^[[:space:]]*(#|$)' "$lib_dir/tier0")
  fi
  if ((ok)); then echo 0; else echo -; fi
}

# all_langs: the default checks' modules
all_langs() {
  local m out=""
  for m in "$lib_dir"/lang/*.sh; do
    m=${m##*/}
    out+="${m%.sh} "
  done
  echo "${out% }"
}

# uncovered ROOT: the modules a repo's check-fast doesn't cover (none, without a covers line)
uncovered() {
  local covers l out=""
  covers=$(sed -n -E '1,40s/^#[[:space:]]*check-fast covers:[[:space:]]*(.*)$/\1/p' "$1/scripts/check-fast" | head -1)
  [[ -n $covers ]] || return 0
  for l in $(all_langs); do
    [[ " $covers " == *" $l "* ]] || out+="$l "
  done
  echo "${out% }"
}

# tier1_langs: modules some finding of which is seen (notify or block), whose tier-1 steps may run; "none" if none
tier1_langs() {
  local l out=""
  for l in $(all_langs); do
    if grep -qE "^${l}(/[^[:space:]]+)?[[:space:]]+(notify|block)" "$modes_file" ||
      { ! grep -qE "^${l}[[:space:]]" "$modes_file" && grep -qE '^\*[[:space:]]+(notify|block)' "$modes_file"; }; then
      out+="$l "
    fi
  done
  out=${out% }
  echo "${out:-none}"
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
# environment when it has one, since agent shells don't load direnv. Sets cfrc
# and allowed; output lands in $tmp/cf.out and $tmp/cf.err.
run_contract() {
  local root=$1 base=$2 try limit
  local -a cmd=("$root/scripts/check-fast")
  if [[ -f $root/.envrc ]] && command -v direnv >/dev/null; then
    cmd=(direnv exec "$root" "${cmd[@]}")
  fi
  allowed=""
  for try in 1 2; do
    cfrc=0
    limit=$(left)
    ((limit < check_timeout)) || limit=$check_timeout
    (cd "$root" && CHECK_BASE=$base timeout "$limit" "${cmd[@]}") >"$tmp/cf.out" 2>"$tmp/cf.err" || cfrc=$?
    # direnv trusts a path, not a repo, so a new worktree's .envrc starts out
    # blocked; the repo opted in, so allow it and run again
    if ((try == 1 && cfrc != 0)) && grep -q 'is blocked' "$tmp/cf.err" && direnv allow "$root" 2>/dev/null; then
      allowed="allowed $root/.envrc for direnv (the repo opted in)"
      continue
    fi
    break
  done
  if ((cfrc == 1)) && [[ ! -s $tmp/cf.out ]]; then
    cfrc=2 # findings with nothing printed: the check failed, not the code
  fi
}

# run_defaults ROOT BASE TIER LANGS [TIER1_LANGS]: the default checks; output in $tmp/d.out and
# $tmp/d.err, exit status in drc. Tier 1 runs inside the repo's direnv environment, as check-fast does, so the
# repo's own toolchains (its Go, its Rust) come first; tier 0 never loads it, since an .envrc is the repo's code.
run_defaults() {
  local root=$1 t1=${5:-$(tier1_langs)} try
  local -a vars=("CHECK_BASE=$2" "AGENT_CHECK_TIER=$3" "AGENT_CHECK_LANGS=$4" "AGENT_CHECK_TIER1_LANGS=$t1"
    "AGENT_CHECK_DEADLINE=$deadline") wrap=()
  if [[ $3 == 1 && -f $root/.envrc ]] && command -v direnv >/dev/null; then
    wrap=(direnv exec "$root")
  fi
  for try in 1 2; do
    drc=0
    (cd "$root" && "${wrap[@]}" env "${vars[@]}" bash "$lib_dir/check-default") >"$tmp/d.out" 2>"$tmp/d.err" || drc=$?
    # A new worktree's .envrc starts out blocked; the clone opted in (tier 1), so allow it and run again
    if ((try == 1 && ${#wrap[@]} > 0)) && grep -q 'is blocked' "$tmp/d.err" && direnv allow "$root" 2>/dev/null; then
      allowed="allowed $root/.envrc for direnv (the repo opted in)"
      continue
    fi
    break
  done
}

# run_checks ROOT BASE TIER: what this clone gets (see the top). Leaves the findings sent to the model in
# $tmp/out, those for the person in $tmp/notify, every finding with its mode in $tmp/all, check-fast's stderr in
# $tmp/err and the defaults' in $tmp/d.err. Sets rc (0 clean, 1 findings to send, else check-fast's broken exit),
# ran (what ran), dbroken (the defaults' failure, if any) and secs.
run_checks() {
  local root=$1 base=$2 tier=$3 t0=$EPOCHREALTIME langs
  : >"$tmp/out"
  : >"$tmp/notify"
  : >"$tmp/all"
  : >"$tmp/err"
  : >"$tmp/d.err"
  allowed=""
  ran=""
  dbroken=""
  cfrc=0
  langs=$(all_langs)
  if [[ $tier == 1 && -x $root/scripts/check-fast ]]; then
    run_contract "$root" "$base"
    ran=check-fast
    langs=$(uncovered "$root")
    cat "$tmp/cf.out" >>"$tmp/out"
    sed 's/^/block\t/' "$tmp/cf.out" >>"$tmp/all"
    cat "$tmp/cf.err" >"$tmp/err"
  fi
  if [[ -n $langs ]]; then
    run_defaults "$root" "$base" "$tier" "$langs"
    ran=${ran:+$ran+}defaults
    awk "$modes_awk" "$modes_file" "$tmp/d.out" >"$tmp/d.cls"
    cat "$tmp/d.cls" >>"$tmp/all"
    awk -F'\t' '$1 == "block"' "$tmp/d.cls" | cut -f2- >>"$tmp/out"
    awk -F'\t' '$1 == "notify"' "$tmp/d.cls" | cut -f2- >>"$tmp/notify"
    if ((drc >= 2)); then dbroken="the default checks failed (exit $drc): $(head -1 "$tmp/d.err")"; fi
  fi
  if [[ -s $tmp/out ]]; then
    rc=1
  elif ((cfrc >= 2)); then
    rc=$cfrc
  else
    rc=0
  fi
  secs=$(awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.1f", b - a }')
}

# errors FILE N: the first N lines of a check's stderr, minus colour codes,
# direnv's and nix-direnv's progress lines (their errors, like a blocked .envrc,
# stay) and nix's dirty-tree warning
errors() {
  sed 's/\x1b\[[0-9;]*m//g' "$1" | awk '
    /^(nix-)?direnv: / && !/error|blocked/ { next }
    /^warning: Git tree .* is dirty$/ { next }
    { print }' | head -"$2"
}

# notes: what the person should hear about this run besides findings and flags. The default checks' own
# notes go to the log only: most are about steps of observed checks, which nobody is waiting on.
notes() {
  if [[ -n $allowed ]]; then echo "agent-check: $allowed"; fi
  if ((rc <= 1)); then errors "$tmp/err" 3; fi
  if [[ -n $dbroken ]]; then echo "agent-check: $dbroken"; fi
  if ((rc == 1 && cfrc >= 2)); then echo "agent-check: scripts/check-fast is broken (exit $cfrc): $(errors "$tmp/cf.err" 1)"; fi
  if [[ -s $tmp/notify ]]; then
    echo "worth a look (not sent to the model):"
    cap "$tmp/notify"
  fi
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
  # The clone's own agent-check settings, which a change to the tree doesn't show
  git -C "$root" config --get-regexp '^agent-check\.' 2>/dev/null | sort >"$tmp/clonecfg" || true
  local cf
  cf=$state_dir/clonecfg/$(hash16 "$root")
  if [[ -f $cf ]] && ! cmp -s "$cf" "$tmp/clonecfg"; then
    echo ".git/config:0: check-config: this clone's agent-check settings changed (git config --get-regexp agent-check); they decide what the checks report, so they're the orchestrator's call"
  fi
  mkdir -p "${cf%/*}"
  cp "$tmp/clonecfg" "$cf"
}

# log REPO SESSION BASE FILES OUTCOME NOTE: one line per check, for reading later
log() {
  local note=${6//$'\n'/ | }
  printf '%s\t%s\t%s\t%s\t%s files\t%s\t%ss\t%s\n' "$(date +%FT%T)" "$1" "${2:0:8}" "${3:0:12}" "$4" "$5" "$secs" "$note" >>"$state_dir/log"
}

# log_findings REPO SESSION PROMPT: every finding of the last run, with its mode, to findings.jsonl; and the
# default checks' notes to notes.log
log_findings() {
  jq -R -c --arg t "$(date +%FT%T)" --arg repo "$1" --arg s "${2:0:8}" --arg p "${3:0:12}" '
    (split("\t")) as $f
    | ($f[1] // "" | capture("^(?<path>[^:]+):(?<line>[0-9]+): (?<rule>[^:]+): (?<msg>.*)$")?) as $c
    | select($c != null)
    | {t: $t, repo: $repo, session: $s, prompt: $p, mode: $f[0], rule: $c.rule, path: $c.path,
       line: ($c.line | tonumber), msg: ($c.msg | .[0:120])}' "$tmp/all" >>"$state_dir/findings.jsonl" || true
  if [[ -s $tmp/d.err ]]; then
    sed "s/^/$(date +%FT%T) $1 /" "$tmp/d.err" >>"$state_dir/notes.log"
  fi
}

# chain_of SESSION PROMPT: the chain a prompt belongs to (a review's rewake carries its chain), or nothing
chain_of() {
  local s=$1 p=$2 f=$state_dir/prompts/$1.json
  safe_id "$p" || return 0
  if safe_id "$s" && [[ -f $f ]] && [[ $(jq -r '.prompt_id // ""' "$f") == "$p" ]]; then
    jq -r '.chain // ""' "$f"
  else
    echo "$p"
  fi
}

# continuations CHAIN: times this chain's turns were sent back
continuations() {
  if [[ -n $1 && -f $state_dir/chains/$1 ]]; then cat "$state_dir/chains/$1"; else echo 0; fi
}

# bump CHAIN: one more continuation
bump() {
  [[ -n $1 ]] || return 0
  local n
  n=$(continuations "$1")
  mkdir -p "$state_dir/chains"
  echo $((n + 1)) >"$state_dir/chains/$1.$$"
  mv "$state_dir/chains/$1.$$" "$state_dir/chains/$1"
}

# check_root ROOT SESSION BUSY CAPPED: one repo's part of a stop. Sets res_block (the reason to send the model
# back, or nothing) and res_note (what the person should hear, or nothing).
check_root() {
  local root=$1 session=$2 busy=$3 capped=$4 tier
  res_block=""
  res_note=""
  tier=$(tier "$root")
  [[ $tier != - ]] || return 0
  local skipped=""
  if [[ $tier == 1 ]] && ((busy > 0)); then
    tier=0
    skipped="tier 1 skipped: background tasks running"
  fi

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

  local name=${root##*/} files note="" fl=- nh=- said who
  files=$(changed_files "$root" "$base" | wc -l | tr -d ' ')
  run_checks "$root" "$base" "$tier"
  log_findings "$name" "$session" "$prompt_id"
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
      note="agent-check ($name), a note from the checks:"$'\n'$said${note:+$'\n'$note}
    fi
  fi
  if [[ $ran == check-fast* ]]; then who="scripts/check-fast"; else who="agent-check"; fi

  if ((rc == 1)); then
    local fh
    fh=$(sha256sum <"$tmp/out" | cut -c1-16)
    if [[ $fh == "$last_findings" ]] || ((blocks >= max_blocks || capped)); then
      # The model was told and didn't (or couldn't) fix it, or this prompt was sent back enough: tell the person
      printf '%s %s 0 %s %s %s\n' "$state" "$fh" "$fl" "$nh" "$head" >"$sf"
      log "$name" "$session" "$base" "$files" "gave-up${skipped:+ ($skipped)}" "$(head -1 "$tmp/out")"
      if ((capped)); then
        res_note="agent-check ($name): this prompt's turn was already sent back $max_continuations times, so these weren't:"
      else
        res_note="agent-check ($name): the turn ended with ${who#scripts/} findings still open:"
      fi
      res_note+=$'\n'$(cap "$tmp/out")${note:+$'\n'$note}
      return 0
    fi
    # Not settled: the next stop still checks everything since the last settle
    printf '%s %s %d %s %s %s\n' "$settled" "$fh" $((blocks + 1)) "$fl" "$nh" "${prev_head:--}" >"$sf"
    log "$name" "$session" "$base" "$files" "block${skipped:+ ($skipped)}" "$(head -1 "$tmp/out")"
    res_block="$who found problems in your changes in $name:"$'\n'$(cap "$tmp/out")
    if grep -q '/format: ' "$tmp/out"; then
      if [[ $base == HEAD ]]; then
        res_block+=$'\n'"Formatting: run agent-check fmt $root"
      else
        res_block+=$'\n'"Formatting: run agent-check fmt $root $base"
      fi
    fi
    res_note=$note
    return 0
  fi

  local outcome=pass
  if ((rc != 0)); then
    # A broken check tells the person and never blocks
    outcome="broken($rc)"
    note="agent-check ($name): scripts/check-fast is broken (exit $rc), so nothing was checked:"$'\n'$(errors "$tmp/cf.err" 3)${note:+$'\n'$note}
  fi
  printf '%s - 0 %s %s %s\n' "$state" "$fl" "$nh" "$head" >"$sf"
  log "$name" "$session" "$base" "$files" "$outcome${skipped:+ ($skipped)}" "$said"
  res_note=$note
}

hook() {
  local input cwd session busy chain capped=0 r m i=0
  input=$(cat)
  [[ ${AGENT_CHECK:-} != off ]] || return 0
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  session=$(jq -r '.session_id // "none"' <<<"$input")
  prompt_id=$(jq -r '.prompt_id // empty' <<<"$input")
  busy=$(jq -r '[.background_tasks[]? | select((.status // "" | ascii_downcase) | test("run|progress|pend|start|queue"))] | length' <<<"$input" 2>/dev/null || echo 0)
  mkdir -p "$state_dir"

  # The repos to check: the one the session is in, and every one this prompt touched
  local -a roots=()
  local -A seen=()
  if r=$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null); then
    roots+=("$r")
    seen[$r]=1
  fi
  if safe_id "$session" && safe_id "$prompt_id" && [[ -d $state_dir/snaps/$session/$prompt_id ]]; then
    for m in "$state_dir/snaps/$session/$prompt_id"/*; do
      [[ -f $m ]] || continue
      r=$(cut -f1 "$m")
      if [[ -n $r && -z ${seen[$r]:-} ]]; then
        roots+=("$r")
        seen[$r]=1
      fi
    done
  fi
  ((${#roots[@]})) || return 0

  chain=$(chain_of "$session" "$prompt_id")
  if [[ -n $chain ]] && (($(continuations "$chain") >= max_continuations)); then capped=1; fi
  local reasons="" msgs=""
  for r in "${roots[@]}"; do
    ((i++ < max_roots)) || break
    check_root "$r" "$session" "$busy" "$capped"
    if [[ -n $res_block ]]; then reasons+=${reasons:+$'\n\n'}$res_block; fi
    if [[ -n $res_note ]]; then msgs+=${msgs:+$'\n'}$res_note; fi
  done

  if [[ -n $reasons ]]; then
    bump "$chain"
    reasons+=$'\n'"Fix them before you finish. If one is wrong, say why in your reply instead of adding a suppression. If you had stopped to ask something, ask it again at the end. Re-check with: agent-check run"
    jq -n --arg r "$reasons" --arg m "$msgs" '{decision: "block", reason: $r} + (if $m == "" then {} else {systemMessage: $m} end)'
  elif [[ -n $msgs ]]; then
    jq -n --arg m "$msgs" '{systemMessage: $m}'
  fi
}

# prompt: the UserPromptSubmit hook. Records the prompt (cut to 2,000 characters, for the review to read as the
# turn's intent) and its chain: its own id, or the chain a review's rewake names in its text.
prompt() {
  local input session prompt_id chain f
  input=$(cat)
  [[ ${AGENT_CHECK:-} != off ]] || return 0
  session=$(jq -r '.session_id // empty' <<<"$input")
  prompt_id=$(jq -r '.prompt_id // empty' <<<"$input")
  safe_id "$session" && safe_id "$prompt_id" || return 0
  chain=$(jq -r '.prompt // "" | (capture("agent-review chain=(?<c>[A-Za-z0-9-]{8,80})").c // empty)' <<<"$input")
  mkdir -p "$state_dir/prompts"
  f=$state_dir/prompts/$session.json
  jq -c --arg chain "${chain:-$prompt_id}" '{prompt_id, chain: $chain, t: (now | floor), prompt: ((.prompt // "") | .[0:2000])}' \
    <<<"$input" >"$f.$$"
  mv "$f.$$" "$f"
  # Old prompts, snapshots and chains go after a week; checked at most once a day
  if [[ ! -f $state_dir/pruned || -n $(find "$state_dir/pruned" -mmin +1440 2>/dev/null) ]]; then
    touch "$state_dir/pruned"
    find "$state_dir/prompts" "$state_dir/snaps" "$state_dir/chains" -mindepth 1 -mtime +7 -delete 2>/dev/null || true
  fi
}

# snapshot ROOT: a tree object of ROOT's working tree as it is now, untracked files included (and ignored ones
# not), written with a scratch index so the repo's own index is never touched
snapshot() {
  local root=$1 src idx=$tmp/index
  src=$(git -C "$root" rev-parse --path-format=absolute --git-path index 2>/dev/null) || return 1
  if [[ -f $src ]]; then cp "$src" "$idx"; else rm -f "$idx"; fi
  GIT_INDEX_FILE=$idx timeout 8 git -C "$root" add -A -- . >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE=$idx git -C "$root" write-tree
}

# snap: the PreToolUse hook. The first time a prompt touches a repo (the file a tool edits, or the directory a
# command runs in), records the repo and a snapshot of its tree. Never blocks: it prints nothing.
snap() {
  local session prompt_id path cwd dir root marker tree
  local -a f=()
  [[ ${AGENT_CHECK:-} != off ]] || return 0
  # It runs before every edit and command, so: one jq, and the marker before anything slower. One field per line:
  # `read` with a tab IFS would merge an empty field (a command has no file path) into the next one.
  mapfile -t f < <(jq -r '.session_id // "", .prompt_id // "",
    (.tool_input.file_path // .tool_input.notebook_path // ""), .cwd // ""')
  session=${f[0]:-} prompt_id=${f[1]:-} path=${f[2]:-} cwd=${f[3]:-}
  safe_id "$session" && safe_id "$prompt_id" || return 0
  if [[ -n $path ]]; then
    dir=$(dirname "$path")
    while [[ ! -d $dir && $dir != / && $dir != . ]]; do dir=$(dirname "$dir"); done
  else
    dir=$cwd
  fi
  root=$(git -C "${dir:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || return 0
  marker=$state_dir/snaps/$session/$prompt_id/$(hash16 "$root")
  [[ -e $marker ]] && return 0
  mkdir -p "${marker%/*}"
  # A repo agent-check doesn't check is marked too, so later touches stop here; the stop skips it
  if [[ $(tier "$root") == - ]]; then
    tree=-
  else
    tree=$(snapshot "$root") || tree=-
  fi
  printf '%s\t%s\n' "$root" "$tree" >"$marker.$$"
  mv "$marker.$$" "$marker"
}

run() {
  local root
  root=$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null) || {
    echo "agent-check: ${1:-.} is not in a git repo" >&2
    return 2
  }
  local name=${root##*/} base=${2:-${CHECK_BASE:-HEAD}} files status=0 outcome said tier label observed
  tier=$(tier "$root")
  if [[ $tier == - ]]; then
    if [[ -x $root/scripts/check-fast ]]; then
      echo "check-fast ($name): not enabled in this clone (git config agent-check.enabled true)"
    else
      echo "check-fast ($name): none"
    fi
    return 0
  fi
  if [[ $tier == 1 && -x $root/scripts/check-fast ]]; then label="check-fast ($name)"; else label="checks ($name, tier $tier)"; fi
  files=$(changed_files "$root" "$base" | wc -l | tr -d ' ')
  if ((files == 0)); then
    echo "$label: nothing to check (no changes since $base)"
    return 0
  fi
  run_checks "$root" "$base" "$tier"
  case $rc in
    0)
      outcome=pass
      echo "$label: pass ($files files)"
      ;;
    1)
      outcome=findings
      echo "$label: findings ($files files)"
      cap "$tmp/out"
      status=1
      ;;
    *)
      outcome="broken($rc)"
      echo "$label: broken (exit $rc)"
      errors "$tmp/cf.err" 5
      status=2
      ;;
  esac
  said=$(notes)
  if [[ -n $said ]]; then
    echo "notes:"
    echo "$said"
  fi
  observed=$(awk -F'\t' '$1 == "observe"' "$tmp/all" | wc -l | tr -d ' ')
  if ((observed > 0)); then echo "observed only (logged, not shown): $observed"; fi
  flags "$root" "$base" >"$tmp/flags"
  if [[ -s $tmp/flags ]]; then
    echo "flags (the orchestrator's call):"
    cap "$tmp/flags"
  fi
  mkdir -p "$state_dir"
  log "$name" run "$base" "$files" "$outcome" "$said"
  log_findings "$name" run ""
  return "$status"
}

# fmt [DIR [BASE]]: formats the changed files the default checks report as unformatted
fmt() {
  local root tier langs
  root=$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null) || {
    echo "agent-check: ${1:-.} is not in a git repo" >&2
    return 2
  }
  tier=$(tier "$root")
  if [[ $tier == - ]]; then
    echo "agent-check fmt: ${root##*/} isn't checked by agent-check" >&2
    return 2
  fi
  langs=$(all_langs)
  if [[ $tier == 1 && -x $root/scripts/check-fast ]]; then langs=$(uncovered "$root"); fi
  if [[ -z $langs ]]; then
    echo "agent-check fmt: ${root##*/}'s own check-fast covers everything; use its formatter" >&2
    return 0
  fi
  (cd "$root" && CHECK_BASE=${2:-${CHECK_BASE:-HEAD}} AGENT_CHECK_TIER=$tier AGENT_CHECK_LANGS=$langs \
    AGENT_CHECK_ACTION=fmt bash "$lib_dir/check-default")
}

# replay DIR [N] [--tier1]: the default checks on each of the last N commits, summed up per rule
replay() {
  local root n=25 t=0 a c parent wt done_n=0
  for a in "$@"; do
    case $a in
      --tier1) t=1 ;;
      [0-9]*) n=$a ;;
      *) root=$a ;;
    esac
  done
  root=$(git -C "${root:-.}" rev-parse --show-toplevel 2>/dev/null) || {
    echo "agent-check: not a git repo" >&2
    return 2
  }
  : >"$tmp/replay"
  wt=$tmp/wt
  git -C "$root" worktree prune
  while read -r c; do
    parent=$(git -C "$root" rev-parse -q --verify "$c^" 2>/dev/null) || continue
    GIT_LFS_SKIP_SMUDGE=1 git -C "$root" -c core.hooksPath=/dev/null worktree add -q --detach "$wt" "$c" 2>/dev/null || continue
    (cd "$wt" && CHECK_BASE=$parent AGENT_CHECK_TIER=$t AGENT_CHECK_TIER1_LANGS=all AGENT_CHECK_LANGS=all \
      AGENT_CHECK_DEADLINE=$(($(date +%s) + 120)) bash "$lib_dir/check-default" 2>>"$tmp/replay.err") |
      sed "s/^/${c:0:8}\t/" >>"$tmp/replay" || true
    git -C "$root" worktree remove --force "$wt"
    done_n=$((done_n + 1))
  done < <(git -C "$root" rev-list --first-parent -n "$n" HEAD)
  echo "replay (${root##*/}): $done_n commits, tier $t"
  if [[ ! -s $tmp/replay ]]; then
    echo "no findings"
    return 0
  fi
  cut -f2- "$tmp/replay" | awk "$modes_awk" "$modes_file" - | cut -f1 >"$tmp/replay.modes"
  paste "$tmp/replay.modes" "$tmp/replay" | awk -F'\t' '
    {
      mode = $1; commit = $2; line = $3
      rule = line; sub(/^[^:]+:[0-9]+: /, "", rule); sub(/: .*$/, "", rule)
      count[rule]++; m[rule] = mode
      if (!((rule, commit) in seen)) { seen[rule, commit] = 1; commits[rule]++ }
      if (!(rule in example)) example[rule] = line
    }
    END {
      printf "%-36s %-8s %8s %8s  %s\n", "rule", "mode", "findings", "commits", "example"
      for (r in count) printf "%-36s %-8s %8d %8d  %s\n", r, m[r], count[r], commits[r], substr(example[r], 1, 90)
    }' | {
    read -r header
    echo "$header"
    sort -k4,4nr -k3,3nr
  }
}

case ${1:-} in
  hook) hook ;;
  prompt) prompt ;;
  snap) snap ;;
  run)
    shift
    run "$@"
    ;;
  fmt)
    shift
    fmt "$@"
    ;;
  replay)
    shift
    replay "$@"
    ;;
  *)
    echo "usage: agent-check hook | prompt | snap | run [DIR [BASE]] | fmt [DIR [BASE]] | replay DIR [N] [--tier1]" >&2
    exit 2
    ;;
esac
