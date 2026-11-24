# shellcheck shell=bash
# swift: Swift, format and lint only. No builds and no tests at any tier: a Swift build takes a shared lock and
# minutes from cold, so it stays in a repo's own check-fast.
#   format (tier 0): swift format (the swift command's swift-format), where the project or the repo root has a
#     .swift-format. Without one there's no project style to follow.
#   lint (tier 0): one run per project, on that project's changed files. swift format lint where there's a
#     .swift-format, swiftlint where there's a .swiftlint.yml. With neither, the module reports nothing.

swift_wants() { [[ $1 =~ \.swift$ ]]; }

# swift_project FILE: the nearest directory with a .swift-format, a .swiftlint.yml or a Package.swift
swift_project() { project_root "$1" .swift-format .swiftlint.yml Package.swift || true; }

# swift_format_config PROJECT: the .swift-format to follow there, falling back to the repo root's; a
# failure when neither has one
swift_format_config() {
  if [[ -f $1/.swift-format ]]; then
    echo "$1/.swift-format"
  elif [[ $1 != . && -f .swift-format ]]; then
    echo .swift-format
  else
    return 1
  fi
}

# swiftlint_config PROJECT: the .swiftlint.yml to lint with, falling back to the repo root's; a failure
# when neither has one
swiftlint_config() {
  if [[ -f $1/.swiftlint.yml ]]; then
    echo "$1/.swiftlint.yml"
  elif [[ $1 != . && -f .swiftlint.yml ]]; then
    echo .swiftlint.yml
  else
    return 1
  fi
}

swift_format() {
  local p cfg
  p=$(swift_project "$1")
  cfg=$(swift_format_config "$p") || return 3
  # Without swift there's no formatter to run; swift_check notes the missing tool once, for the whole module.
  command -v swift >/dev/null || return 3
  bounded swift format --configuration "$cfg" -
}

swift_check() {
  local f p cfg rc path line rule msg first
  local -A projects=()
  for f in "$@"; do
    p=$(swift_project "$f")
    projects[$p]+="$f"$'\n'
  done
  check_format "$@"

  for p in "${!projects[@]}"; do
    local -a files=()
    mapfile -t files < <(printf '%s' "${projects[$p]}")

    # swift-format's own lint, on the changed files
    if cfg=$(swift_format_config "$p"); then
      if need swift "swift format lint in $p"; then
        rc=0
        bounded swift format lint --configuration "$cfg" "${files[@]}" >"$(scratch swift-format.out)" 2>&1 || rc=$?
        if ((rc == 124)); then
          note "swift format lint ran out of time in $p"
        elif ((rc != 0)); then
          # a file it can't parse, or a configuration it can't read
          first=$(head -1 "$(scratch swift-format.out)")
          note "skipped swift format lint in $p: ${first:-exit $rc}"
        else
          # a.swift:2:8: warning: [Spacing] remove 1 space, with the path as given
          sed -n -E 's|^([^:]+):([0-9]+):[0-9]+: warning: \[([^]]+)\] (.*)$|\1\t\2\t\3\t\4|p' "$(scratch swift-format.out)" |
            while IFS=$'\t' read -r path line rule msg; do
              finding warn "$path" "$line" "swift-format-$rule" "$msg"
            done
        fi
      fi
    fi

    # SwiftLint, on the changed files
    if cfg=$(swiftlint_config "$p"); then
      if need swiftlint "swiftlint lint in $p"; then
        rc=0
        bounded swiftlint lint --quiet --no-cache --config "$cfg" "${files[@]}" \
          >"$(scratch swiftlint.out)" 2>"$(scratch swiftlint.err)" || rc=$?
        # 2 only means a violation had error severity; the findings below stay warns
        if ((rc == 124)); then
          note "swiftlint ran out of time in $p"
        elif ((rc != 0 && rc != 2)); then
          first=$(head -1 "$(scratch swiftlint.err)")
          note "skipped swiftlint in $p: ${first:-exit $rc}"
        else
          # /abs/a.swift:2:10: warning: Colon Spacing Violation: Colons should be ... (colon)
          sed -n -E 's|^(.*):([0-9]+):[0-9]+: [a-z]+: (.*) \(([a-z0-9_.]+)\)$|\1\t\2\t\3\t\4|p' "$(scratch swiftlint.out)" |
            while IFS=$'\t' read -r path line msg rule; do
              finding warn "$(from_repo "$path")" "$line" "swiftlint-$rule" "$msg"
            done
        fi
      fi
    fi
  done
}
