# shellcheck shell=bash
# go: Go.
#   format (tier 0): gofumpt where the project or the repo root mentions it, gofmt otherwise.
#   lint (tier 1): golangci-lint, once per project, on what the change adds. Its JSON carries the compiler's
#     errors too (the typecheck issues: unused imports and variables are compile errors in Go), which count
#     wherever they are.
#   tests (tier 1): go test -json for the packages the change touches; a failing test reports where it failed.
#
# Every go and golangci-lint run sits in the project directory with GOTOOLCHAIN=local, so a go.mod `toolchain`
# line never downloads a Go.

go_wants() { [[ $1 == *.go ]]; }

# go_project FILE: the nearest directory with a go.mod; fails when there isn't one above FILE
go_project() { project_root "$1" go.mod; }

# go_uses_gofumpt PROJECT: the project, or the repo root, asks for gofumpt rather than gofmt
go_uses_gofumpt() {
  local p=$1 f
  for f in .golangci.yml .golangci.yaml Makefile justfile flake.nix .pre-commit-config.yaml; do
    if grep -qs gofumpt "$p/$f"; then return 0; fi
    if [[ $p != . ]] && grep -qs gofumpt "$f"; then return 0; fi
  done
  return 1
}

# go_module PROJECT: the module path in its go.mod
go_module() {
  sed -n -E 's/^module[[:space:]]+"?([^"[:space:]]+)"?.*/\1/p' "$1/go.mod" | head -1
}

go_format() {
  local p tool
  p=$(go_project "$1") || return 3
  tool=gofmt
  if command -v gofumpt >/dev/null && go_uses_gofumpt "$p"; then tool=gofumpt; fi
  need "$tool" "Go formatting" || return 3
  "$tool"
}

go_check() {
  local f p
  local -A projects=()
  local -a wanted=()

  for f in "$@"; do
    if p=$(go_project "$f"); then
      projects[$p]+="$f"$'\n'
      wanted+=("$f")
    else
      note "$f has no go.mod above it, so it isn't checked"
    fi
  done
  ((${#wanted[@]})) || return 0
  check_format "${wanted[@]}"
  tier1 || return 0

  for p in "${!projects[@]}"; do
    local -a files=()
    mapfile -t files < <(printf '%s' "${projects[$p]}")
    go_lint "$p"
    go_tests "$p" "${files[@]}"
  done
}

# go_lint PROJECT: golangci-lint over the whole project, keeping what the change adds (--new-from-rev).
# Its exit status says nothing about findings; the JSON on stdout does.
go_lint() {
  local p=$1 abs rev rc=0 linter path line text
  need golangci-lint "the Go lint" || return 0
  # The base the change is measured from, when it names a commit; HEAD when it doesn't
  rev=${base-HEAD}
  git rev-parse -q --verify "$rev^{commit}" >/dev/null 2>&1 || rev=HEAD
  abs=$(cd "$p" && pwd -P)
  (cd "$abs" &&
    bounded env GOTOOLCHAIN=local golangci-lint run --new-from-rev="$rev" \
      --output.json.path=stdout --output.text.path=/dev/null --show-stats=false ./...) \
    >"$(scratch golangci.json)" 2>"$(scratch golangci.err)" || rc=$?
  if ((rc == 124)); then
    note "golangci-lint ran out of time in $p"
    return 0
  fi
  if ! [[ -s $(scratch golangci.json) ]] || ! jq -e 'has("Issues")' "$(scratch golangci.json)" >/dev/null 2>&1; then
    note "skipped golangci-lint in $p: $(head -1 "$(scratch golangci.err)")"
    return 0
  fi

  # Lint findings, at the line the linter saw
  jq -r '.Issues[]? | select(.FromLinter != "typecheck") |
    [.FromLinter, (.Pos.Filename // ""), (.Pos.Line // 1), (.Text // "")] | @tsv' \
    "$(scratch golangci.json)" |
    while IFS=$'\t' read -r linter path line text; do
      [[ -n $path ]] || continue
      finding warn "$(in_project "$p" "$path")" "$line" "golangci-$linter" "$text"
    done

  # typecheck packs the compiler's errors into one issue's Text, one `path:line:col: message` per line;
  # its own Pos (line 1 of some file) means nothing.
  jq -r '.Issues[]? | select(.FromLinter == "typecheck") | .Text // ""' "$(scratch golangci.json)" |
    sed -n -E 's|^([^:]+):([0-9]+):([0-9]+): (.*)$|\1\t\2\t\4|p' |
    while IFS=$'\t' read -r path line text; do
      finding error "$(in_project "$p" "$path")" "$line" compile "$text"
    done
}

# go_tests PROJECT FILES...: go test for the packages the changed files sit in
go_tests() {
  local p=$1 mod f rel d pkg test out file line rc=0 abs cand
  shift
  need go "go test" || return 0

  local -A dirs=()
  for f in "$@"; do
    rel=${f#"$p"/}
    d=$(dirname "$rel")
    [[ $d == . ]] || d=./${d#./}
    dirs[$d]=1
  done
  local -a pkgs=()
  for d in "${!dirs[@]}"; do pkgs+=("$d"); done

  mod=$(go_module "$p")
  abs=$(cd "$p" && pwd -P)
  (cd "$abs" && bounded env GOTOOLCHAIN=local go test -json "${pkgs[@]}") \
    >"$(scratch gotest.json)" 2>"$(scratch gotest.err)" || rc=$?
  if ((rc == 124)); then
    note "go test ran out of time in $p"
    return 0
  fi
  if ((rc != 0)) && ! grep -q '^{' "$(scratch gotest.json)"; then
    note "skipped go test in $p: $(head -1 "$(scratch gotest.err)")"
    return 0
  fi

  # One line per failed test: its package, its name and everything it printed. Non-JSON lines and a
  # package that failed to build (no Test) are lint's business, not ours.
  jq -R -r 'fromjson? | select(.Test != null) | [.Action, .Package // "", .Test, (.Output // "")] | @tsv' \
    "$(scratch gotest.json)" |
    awk -F'\t' '
      $1 == "output" { buf[$2 SUBSEP $3] = buf[$2 SUBSEP $3] $4; next }
      $1 == "fail" { print $2 "\t" $3 "\t" buf[$2 SUBSEP $3]; buf[$2 SUBSEP $3] = "" }
    ' >"$(scratch gotest.fails)"

  while IFS=$'\t' read -r pkg test out; do
    # The package's directory: its import path with the module path cut off the front
    d=${pkg#"$mod"/}
    [[ $d == "$pkg" ]] && d=.
    file=""
    line=1
    if [[ $out =~ ([A-Za-z0-9_]+_test\.go):([0-9]+) ]]; then
      file=${BASH_REMATCH[1]}
      line=${BASH_REMATCH[2]}
    else
      for cand in "$p/$d"/*_test.go; do
        [[ -e $cand ]] || continue
        file=${cand##*/}
        break
      done
    fi
    [[ -n $file ]] || file=go.mod
    if [[ $d == . ]]; then rel=$file; else rel=$d/$file; fi
    finding error "$(in_project "$p" "$rel")" "$line" test "failed: $test"
  done <"$(scratch gotest.fails)"
}
