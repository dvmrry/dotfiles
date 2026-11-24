# shellcheck shell=bash
# ts: TypeScript and JavaScript, after medina's and relay's check-fast. The pattern for every other module.
#   format (tier 0): Biome, where the project has a biome.json(c). Without one there's no project style to follow
#     (Biome's own default indents with tabs).
#   lint (tier 0): Biome's lint on the changed files, unless the project lints with ESLint instead.
#   Either is skipped where the project pins its own Biome: tier 0 doesn't run it, and tier 1 runs that one.
#   types (tier 1): tsc --noEmit for each project with a tsconfig.json; type errors count anywhere.
#   tests (tier 1): bun test in Bun projects; a failing test reports its file and name.

ts_wants() { [[ $1 =~ \.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$ ]]; }

# ts_project FILE: the nearest directory with a package.json or tsconfig.json
ts_project() { project_root "$1" package.json tsconfig.json || true; }

ts_has_biome_config() { [[ -f $1/biome.json || -f $1/biome.jsonc || -f biome.json || -f biome.jsonc ]]; }

ts_has_eslint_config() {
  compgen -G "$1/.eslintrc*" >/dev/null || compgen -G "$1/eslint.config.*" >/dev/null ||
    jq -e 'has("eslintConfig")' "$1/package.json" >/dev/null 2>&1
}

# ts_biome PROJECT: the Biome to run for that project, or a failure when none may run
ts_biome() {
  local p=$1
  if pinned "$p" biome; then
    tier1 || return 1
    echo "$PWD/$p/node_modules/.bin/biome"
    return 0
  fi
  # Pinned in package.json but not installed: its version may disagree with ours
  if jq -e '(.devDependencies // {}) + (.dependencies // {}) | has("@biomejs/biome")' "$p/package.json" >/dev/null 2>&1; then
    return 1
  fi
  command -v biome
}

ts_format() {
  local p b
  p=$(ts_project "$1")
  ts_has_biome_config "$p" || return 3
  b=$(ts_biome "$p") || return 3
  (cd "$p" && "$b" format --stdin-file-path="${1#"$p"/}")
}

ts_check() {
  local f p b tsc_bin
  local -A projects=()
  for f in "$@"; do
    p=$(ts_project "$f")
    projects[$p]+="$f"$'\n'
  done
  check_format "$@"

  for p in "${!projects[@]}"; do
    local -a files=()
    mapfile -t files < <(printf '%s' "${projects[$p]}")

    # Lint, on the changed files
    if ts_has_eslint_config "$p" && ! ts_has_biome_config "$p"; then
      note "$p lints with ESLint, which isn't one of ours to run"
    elif b=$(ts_biome "$p"); then
      (cd "$p" && bounded "$b" lint --reporter=github --max-diagnostics=200 "${files[@]#"$p"/}" 2>/dev/null) |
        sed -n -E 's/^::[a-z]+ title=lint\/[a-zA-Z]+\/([A-Za-z]+),file=([^,]+),line=([0-9]+)[^:]*::(.*)$/\2\t\3\t\1\t\4/p' |
        while IFS=$'\t' read -r path line rule msg; do
          finding warn "$(from_repo "$path")" "$line" "biome-$rule" "$msg"
        done
    else
      note "skipped Biome in $p: the project pins its own"
    fi

    # Types, across the project: a change can break another file
    if tier1 && [[ -f $p/tsconfig.json ]]; then
      if [[ ! -d $p/node_modules ]] && jq -e '(.dependencies // {}) + (.devDependencies // {}) | length > 0' "$p/package.json" >/dev/null 2>&1; then
        note "skipped tsc in $p: its dependencies aren't installed (bun install)"
      else
        tsc_bin=$(command -v tsc || true)
        if pinned "$p" tsc; then tsc_bin=$PWD/$p/node_modules/.bin/tsc; fi
        if [[ -n $tsc_bin ]]; then
          local rc=0
          (cd "$p" && bounded "$tsc_bin" --noEmit -p . --pretty false) >"$(scratch tsc.out)" 2>&1 || rc=$?
          if ((rc == 124)); then note "tsc ran out of time in $p"; fi
          sed -n -E 's/^([^(]+)\(([0-9]+),[0-9]+\): error (TS[0-9]+): (.*)$/\1\t\2\t\3\t\4/p' "$(scratch tsc.out)" |
            while IFS=$'\t' read -r path line code msg; do
              finding error "$(in_project "$p" "$path")" "$line" "tsc-$code" "$msg"
            done
        else
          note "tsc not found"
        fi
      fi
    fi

    # Tests: a failing test reports where it failed
    if tier1 && [[ -f $p/bun.lock || -f $p/bun.lockb ]] && need bun "bun test"; then
      local rc=0
      (cd "$p" && bounded bun test) >"$(scratch bun.out)" 2>&1 || rc=$?
      if ((rc == 124)); then
        note "bun test ran out of time in $p"
      elif ((rc != 0)); then
        # bun prints "(/abs/path/x.test.ts:LINE" in a failure's trace, then "(fail) name [time]"
        awk -v root="$(cd "$p" && pwd -P)/" '
          match($0, /\(\/[^:)]+\.test\.[jt]sx?:[0-9]+/) {
            s = substr($0, RSTART + 1, RLENGTH - 1)
            ln = s; sub(/^.*:/, "", ln)
            sub(/:[0-9]+$/, "", s)
            if (index(s, root) == 1) s = substr(s, length(root) + 1)
            loc = s
          }
          /^\(fail\) / {
            name = substr($0, 8); sub(/ \[[0-9.]+m?s\]$/, "", name)
            print (loc != "" ? loc : "package.json") "\t" (ln != "" ? ln : 0) "\t" name
            loc = ""; ln = ""
          }
        ' "$(scratch bun.out)" >"$(scratch bun.fails)"
        if [[ ! -s $(scratch bun.fails) ]]; then
          printf 'package.json\t0\t%s\n' "$(grep -m1 -E 'error' "$(scratch bun.out)" || echo 'bun test failed')" >"$(scratch bun.fails)"
        fi
        while IFS=$'\t' read -r path line name; do
          finding error "$(in_project "$p" "$path")" "$line" bun-test "failed: $name"
        done <"$(scratch bun.fails)"
      fi
    fi
  done
}
