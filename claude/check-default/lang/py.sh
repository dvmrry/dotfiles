# shellcheck shell=bash
# py: Python, after ruff.
#   lint (tier 0): ruff check on each project's changed files. The project's own ruff config decides the rules;
#     without one ruff runs --isolated, so whoever's machine this is doesn't decide what a repo is checked for.
#   format (tier 0): ruff format, where the project has a ruff config. Without one there's no project style to
#     follow.
#   No tier 1: pytest needs the project's own environment, so it stays in a repo's own check-fast.

py_wants() {
  local b=${1##*/}
  [[ $b == *.py ]] && return 0
  [[ $b == *.* ]] && return 1
  head -1 "$1" 2>/dev/null | grep -qE '^#!.*python[0-9.]*([[:space:]]|$)'
}

# py_project FILE: the nearest directory with a pyproject.toml, ruff.toml or .ruff.toml
py_project() { project_root "$1" pyproject.toml ruff.toml .ruff.toml || true; }

# py_has_ruff_config PROJECT: the project sets its own rules, so ruff doesn't need --isolated
py_has_ruff_config() {
  local p=$1
  [[ -f $p/ruff.toml || -f $p/.ruff.toml ]] && return 0
  [[ -f $p/pyproject.toml ]] && grep -qF '[tool.ruff' "$p/pyproject.toml"
}

py_format() {
  local p
  p=$(py_project "$1")
  py_has_ruff_config "$p" || return 3
  command -v ruff >/dev/null || return 3
  (cd "$p" && ruff format --no-cache --stdin-filename "${1#"$p"/}" -)
}

py_check() {
  local f p
  local -A projects=()
  for f in "$@"; do
    p=$(py_project "$f")
    projects[$p]+="$f"$'\n'
  done
  check_format "$@"

  need ruff "the Python lint" || return 0
  for p in "${!projects[@]}"; do
    local -a files=()
    mapfile -t files < <(printf '%s' "${projects[$p]}")
    py_lint "$p" "${files[@]}"
  done
}

# py_lint PROJECT FILE...: ruff check, from the project directory, on that project's changed files
py_lint() {
  local p=$1 rc=0 why
  shift
  local -a files=("$@") iso=()
  local out err res
  local path line code msg

  out=$(scratch py.check)
  err=$(scratch py.err)
  res=$(scratch py.findings)

  py_has_ruff_config "$p" || iso=(--isolated)
  # --no-cache: ruff must not write .ruff_cache into the repo
  (
    cd "$p" &&
      bounded ruff check --no-cache ${iso[@]+"${iso[@]}"} --output-format=json "${files[@]#"$p"/}"
  ) >"$out" 2>"$err" || rc=$?
  if ((rc == 124)); then
    note "ruff ran out of time in $p"
    return 0
  fi
  if ((rc != 0 && rc != 1)); then
    why=$(head -1 "$err")
    note "skipped ruff in $p: ${why:-it exited $rc}"
    return 0
  fi

  if ! jq -r '.[] | [.filename, (.location.row // 1), (.code // ""), (.message // "")] | @tsv' "$out" >"$res" 2>"$err"; then
    note "skipped ruff's findings in $p: $(head -1 "$err")"
    return 0
  fi
  while IFS=$'\t' read -r path line code msg; do
    [[ -n $path ]] || continue
    # ruff reports a file it can't parse with no code (older ruff) or the code invalid-syntax
    if [[ -z $code || $code == invalid-syntax ]]; then
      finding error "$(from_repo "$path")" "$line" ruff-syntax "${msg:-does not parse}"
    else
      finding warn "$(from_repo "$path")" "$line" "ruff-$code" "$msg"
    fi
  done <"$res"
}
