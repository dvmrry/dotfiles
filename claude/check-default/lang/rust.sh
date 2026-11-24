# shellcheck shell=bash
# rust: Rust, after a normal cargo setup.
#   format (tier 0): rustfmt, with the edition the project's Cargo.toml asks for (2021 when it doesn't say) and
#     the project's or the repo's rustfmt.toml when there is one. A .rs file with no Cargo.toml above it isn't
#     part of a Rust project, so it's left alone.
#   lint and build errors (tier 1): cargo clippy --all-targets, once per cargo root: the workspace root when the
#     package belongs to one (cargo names files relative to it), else the package. It builds into that root's own
#     target/, which tier 1 allows, and passes --locked when there's a Cargo.lock, so it never rewrites a committed
#     one (a change that needs the lock updated is the orchestrator's call; clippy then says so in a note).
#     Compiler and clippy warnings count on the lines the change added; errors count anywhere.
#   tests (tier 1): cargo test, after clippy and only when clippy reported no error; a panicking test reports
#     where it panicked.

rust_wants() { [[ $1 =~ \.rs$ ]]; }

# rust_root FILE: where cargo runs for FILE: the outermost directory up to the repo root whose Cargo.toml has a
# [workspace] table, when there is one above the file's package; else the package's directory. Fails when no
# Cargo.toml is above FILE.
rust_root() {
  local p d
  p=$(project_root "$1" Cargo.toml) || return 1
  d=$p
  while [[ $d != . ]]; do
    d=$(dirname "$d")
    if grep -qs '^\[workspace\]' "$d/Cargo.toml"; then p=$d; fi
  done
  echo "$p"
}

# rust_cargo_args ROOT: --workspace for a workspace root, --locked when there's a Cargo.lock
rust_cargo_args() {
  if grep -qs '^\[workspace\]' "$1/Cargo.toml"; then echo --workspace; fi
  if [[ -f $1/Cargo.lock ]]; then echo --locked; fi
}

# rust_edition PROJECT: the edition Cargo.toml asks for, 2021 when it doesn't say
rust_edition() {
  local e
  e=$(sed -n -E 's/^[[:space:]]*edition[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$1/Cargo.toml" 2>/dev/null | head -1)
  echo "${e:-2021}"
}

# rust_config PROJECT: the rustfmt.toml to pass with --config-path, in the project or at the repo root
rust_config() {
  local p=$1 c
  for c in "$p/rustfmt.toml" "$p/.rustfmt.toml" rustfmt.toml .rustfmt.toml; do
    if [[ -f $c ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

rust_format() {
  local p e c
  local -a args=()
  p=$(project_root "$1" Cargo.toml) || return 3
  command -v rustfmt >/dev/null || return 3
  e=$(rust_edition "$p")
  args=(--edition "$e")
  if c=$(rust_config "$p"); then
    args+=(--config-path "$c")
  fi
  rustfmt "${args[@]}"
}

rust_check() {
  local f p
  local -A projects=()

  for f in "$@"; do
    if p=$(rust_root "$f"); then
      projects[$p]+="$f"$'\n'
    else
      note "$f: no Cargo.toml above it, skipped"
    fi
  done

  check_format "$@"
  tier1 || return 0
  need cargo "cargo clippy and cargo test" || return 0

  for p in "${!projects[@]}"; do
    if rust_clippy "$p"; then
      rust_test "$p"
    else
      note "skipped cargo test in $p: clippy did not finish cleanly"
    fi
  done
}

# rust_clippy PROJECT: cargo clippy's diagnostics as findings. Fails when it ran out of time, failed to run or
# reported an error, which is when the tests aren't worth running.
rust_clippy() {
  local p=$1 rc=0 errs=0 path line rule level msg
  local json err diag
  json=$(scratch rust.clippy.json)
  err=$(scratch rust.clippy.err)
  diag=$(scratch rust.clippy.diag)

  local -a extra=()
  mapfile -t extra < <(rust_cargo_args "$p")
  (cd "$p" && bounded cargo clippy ${extra[@]+"${extra[@]}"} --all-targets --message-format=json) >"$json" 2>"$err" || rc=$?
  if ((rc == 124)); then
    note "clippy ran out of time (a cold build takes longer) in $p"
    return 2
  fi

  # One JSON object per line; each diagnostic comes twice over, once per target, so keep the first of each.
  jq -r '
    select(.reason == "compiler-message") | .message as $m |
    select($m.level == "error" or $m.level == "warning") |
    ([$m.spans[]? | select(.is_primary == true)] | first) as $s |
    select($s != null) |
    select((($s.file_name | startswith("/")) | not) and (($s.file_name | startswith("..")) | not)) |
    [ $s.file_name, ($s.line_start | tostring),
      (if $m.code == null then "rustc-error"
       elif (($m.code.code // "") | startswith("clippy::")) then "clippy-" + ($m.code.code | sub("^clippy::"; ""))
       else "rustc-" + $m.code.code end),
      $m.level, ($m.message | gsub("[\n\t]"; " ")) ] | @tsv' "$json" 2>/dev/null |
    awk -F'\t' '!seen[$1 FS $2 FS $3]++' >"$diag"

  if [[ ! -s $diag ]] && ((rc != 0)); then
    note "clippy failed in $p: $(head -1 "$err")"
    return 1
  fi

  while IFS=$'\t' read -r path line rule level msg; do
    if [[ $level == error ]]; then
      errs=$((errs + 1))
      finding error "$(in_project "$p" "$path")" "$line" "$rule" "$msg"
    else
      finding warn "$(in_project "$p" "$path")" "$line" "$rule" "$msg"
    fi
  done <"$diag"

  ((errs == 0))
}

# rust_test PROJECT: a failing test is a finding where it panicked
rust_test() {
  local p=$1 rc=0 n=0 line first
  local re="^thread '([^']+)'( \([0-9]+\))? panicked at ([^:]+):([0-9]+):"
  local out
  out=$(scratch rust.test)

  local -a extra=()
  mapfile -t extra < <(rust_cargo_args "$p")
  (cd "$p" && bounded cargo test ${extra[@]+"${extra[@]}"} --quiet) >"$out" 2>&1 || rc=$?
  if ((rc == 124)); then
    note "cargo test ran out of time in $p"
    return 0
  fi
  ((rc == 0)) && return 0

  while IFS= read -r line; do
    [[ $line =~ $re ]] || continue
    finding error "$(in_project "$p" "${BASH_REMATCH[3]}")" "${BASH_REMATCH[4]}" test "failed: ${BASH_REMATCH[1]}"
    n=$((n + 1))
  done <"$out"

  if ((n == 0)); then
    first=$(grep -m1 -v '^[[:space:]]*$' "$out" || true)
    note "cargo test failed in $p: ${first:-no output}"
  fi
}
