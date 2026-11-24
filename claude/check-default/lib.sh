# shellcheck shell=bash
# lib.sh: what agent-check's default checks share. check-default sources it, then each module in lang/.
#
# A module, lang/NAME.sh, defines:
#   NAME_wants FILE     succeeds when the module checks FILE (a path from the repo root)
#   NAME_check FILE...  reports findings, with `finding`, for the changed files it wants
#   NAME_format FILE    optional: reads FILE's text on stdin and prints it formatted; exits 3 when no formatter
#                       applies (the project has no style to follow, or formats with a tool we don't run)
# Before anything that builds, type checks, runs tests or runs one of the repo's own tools, a module asks
# `tier1`. lang/ts.sh is the pattern to follow.
#
# check-default sets these once it has sourced this file: base (what the change is measured from), tier, work
# (a scratch directory), lang (the module running), deadline (epoch seconds) and top (the repo root, resolved).
base=${base-} tier=${tier-} work=${work-} lang=${lang-} deadline=${deadline-} top=${top-}

# scratch NAME: a path for a module's scratch file
scratch() { echo "$work/$1"; }

# finding error|warn PATH LINE RULE MESSAGE
#   error: reported wherever it is (a type error, a failing test, a secret)
#   warn: only on a line the change adds, or anywhere in a new file, so a touched file's old findings stay quiet
finding() {
  local sev=$1 path=$2 line=$3 rule=$4 msg=$5
  if [[ $sev == warn ]] && ! added "$path" "$line"; then return 0; fi
  printf '%s:%s: %s/%s: %s\n' "$path" "$line" "$lang" "$rule" "${msg//$'\n'/ }" >>"$work/findings"
}

# added PATH LINE: the change adds that line, or the whole file
added() { grep -qxF -- "$1" "$work/new" || grep -qxF -- "$1:$2" "$work/added"; }

# note MESSAGE: a line for whoever reads the log, such as a step that was skipped
note() { echo "check-default ($lang): $*" >&2; }

# need TOOL [WHAT]: the tool is on PATH, or a note says what was skipped
need() {
  command -v "$1" >/dev/null && return 0
  note "$1 not found${2:+, so $2 was skipped}"
  return 1
}

# tier1: this run may build, type check, run tests and run the repo's own tools. That needs a clone that opted
# in, and a module whose findings someone sees: agent-check passes the languages that aren't only observed.
tier1() {
  [[ $tier == 1 ]] || return 1
  [[ ${AGENT_CHECK_TIER1_LANGS:-all} == all || " ${AGENT_CHECK_TIER1_LANGS:-} " == *" $lang "* ]]
}

# left: seconds until the deadline, at least 1
left() {
  local n=$((deadline - $(date +%s)))
  echo $((n > 0 ? n : 1))
}

# bounded CMD...: runs CMD in what's left of the time; exit 124 means it ran out
bounded() { timeout "$(left)" "$@"; }

# project_root FILE MARKER...: the nearest directory above FILE, up to the repo root, holding one of the
# markers; the repo root (and a failure) when none does
project_root() {
  local dir m
  dir=$(dirname "$1")
  shift
  while :; do
    for m in "$@"; do
      if [[ -e $dir/$m ]]; then
        echo "$dir"
        return 0
      fi
    done
    [[ $dir == . ]] && break
    dir=$(dirname "$dir")
  done
  echo .
  return 1
}

# in_project PROJECT PATH: PATH (relative to PROJECT) as a path from the repo root
in_project() {
  local p=$1 path=${2#./}
  if [[ $p == . ]]; then echo "$path"; else echo "$p/$path"; fi
}

# from_repo PATH: an absolute PATH that a tool printed, made relative to the repo root
from_repo() {
  local path=$1
  path=${path#"$top"/}
  echo "${path#"$PWD"/}"
}

# pinned PROJECT TOOL: the project brings its own installed copy of TOOL, which tier 0 must not run
pinned() { [[ -x $1/node_modules/.bin/$2 ]]; }

# at_base PATH: the file's text at the base; fails when it didn't exist there
at_base() { git show "$base:$1" 2>/dev/null; }

# formatted FILE IN OUT: the module's formatter on IN; 0 (OUT holds the result), 3 (no formatter applies) or
# another failure
formatted() { "${lang}_format" "$1" <"$2" >"$3" 2>"$work/fmt.err"; }

# format_state FILE: clean; dirty (the change left it unformatted, or it's new and unformatted); legacy (it was
# already unformatted at the base, so its formatting isn't this change's); none (no formatter); failed
format_state() {
  local f=$1 rc=0
  formatted "$f" "$f" "$work/fmt.out" || rc=$?
  if ((rc == 3)); then
    echo none
    return
  fi
  if ((rc != 0)); then
    echo failed
    return
  fi
  if cmp -s "$f" "$work/fmt.out"; then
    echo clean
    return
  fi
  if at_base "$f" >"$work/base.txt"; then
    rc=0
    formatted "$f" "$work/base.txt" "$work/base.fmt" || rc=$?
    if ((rc == 0)) && ! cmp -s "$work/base.txt" "$work/base.fmt"; then
      echo legacy
      return
    fi
  fi
  echo dirty
}

# check_format FILE...: a finding for each file the change left unformatted, at the first line that differs
check_format() {
  local f line
  for f in "$@"; do
    case $(format_state "$f") in
      dirty)
        line=$(diff "$f" "$work/fmt.out" | sed -n '1s/^\([0-9]*\).*/\1/p')
        finding error "$f" "${line:-1}" format "not formatted; run agent-check fmt"
        ;;
      failed)
        note "the formatter failed on $f: $(head -1 "$work/fmt.err")"
        ;;
    esac
  done
}

# apply_format FILE...: formats the files check_format would report, and says which
apply_format() {
  local f
  for f in "$@"; do
    if [[ $(format_state "$f") == dirty ]]; then
      cat "$work/fmt.out" >"$f"
      echo "formatted $f"
    fi
  done
}
