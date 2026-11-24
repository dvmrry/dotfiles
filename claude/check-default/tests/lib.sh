# shellcheck shell=bash
# tests/lib.sh: what the module tests share. A module's tests live in tests/NAME.sh (tests/ts.sh is the pattern):
# each builds small repos, runs check-default on them and checks its findings. Run them with tests/run.sh [NAME...].

t_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) # claude/check-default
t_work=$(mktemp -d)
trap 'rm -rf "$t_work"' EXIT
# Nothing from the person's own state or config
export XDG_STATE_HOME=$t_work/state XDG_CONFIG_HOME=$t_work/config
fails=0

# t_repo NAME: a new repo in the scratch directory, whose origin tier0 lists; prints its path
t_repo() {
  local d=$t_work/$1
  git init -q "$d"
  git -C "$d" remote add origin "https://github.com/dvmrry/$1.git"
  echo "$d"
}

# t_commit DIR [MESSAGE]: commits everything in DIR
t_commit() {
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@t commit -q -m "${2:-commit}"
}

# t_check DIR [VAR=VALUE...]: check-default's findings for DIR's changes, at tier 0 unless a VAR says otherwise.
# Its stderr (the notes) lands in $t_work/err.
t_check() {
  local d=$1
  shift
  (cd "$d" && env AGENT_CHECK_TIER=0 "$@" bash "$t_dir/check-default" 2>"$t_work/err") || true
}

# t_notes: the notes of the last t_check or t_fmt
t_notes() { cat "$t_work/err"; }

# t_fmt DIR [VAR=VALUE...]: formats DIR's changed files; prints what it formatted
t_fmt() {
  local d=$1
  shift
  (cd "$d" && env AGENT_CHECK_TIER=0 AGENT_CHECK_ACTION=fmt "$@" bash "$t_dir/check-default" 2>"$t_work/err") || true
}

# expect NAME REGEX TEXT: TEXT matches REGEX (an empty REGEX means TEXT is empty)
expect() {
  local name=$1 pattern=$2 out=$3
  if [[ -z $pattern && -z $out ]] || [[ -n $pattern && $out =~ $pattern ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: got: ${out:-<nothing>}"
    fails=$((fails + 1))
  fi
}

# absent NAME FRAGMENT TEXT: TEXT doesn't contain FRAGMENT
absent() {
  if [[ $3 == *"$2"* ]]; then
    echo "FAIL $1: found \"$2\" in: $3"
    fails=$((fails + 1))
  else
    echo "ok   $1"
  fi
}

# t_done: the summary line, and the exit status
t_done() {
  if ((fails > 0)); then
    echo "$fails failed"
    exit 1
  fi
  echo "all passed"
}
