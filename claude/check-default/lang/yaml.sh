# shellcheck shell=bash
# yaml: YAML, and GitHub Actions workflows.
#   workflows (tier 0): actionlint, on each changed file under a .github/workflows/ directory, one file at a
#     time. Workflows are actionlint's alone: yamllint doesn't look at them.
#   lint (tier 0): yamllint, on every other changed .yml/.yaml at once, with the repo's own .yamllint when it has
#     one and yamllint's relaxed profile otherwise. A file that doesn't parse is an error; everything else is a
#     lint warning, so lib.sh reports it only on the lines the change added.
# No formatter: yamllint's own defaults disagree with most repos' config, so there's no style of ours to apply.

yaml_wants() { [[ $1 =~ \.ya?ml$ ]]; }

# yaml_workflow FILE: a GitHub Actions workflow, at any depth in the repo
yaml_workflow() { [[ $1 =~ (^|/)\.github/workflows/.+\.ya?ml$ ]]; }

# yaml_path PATH: a path a tool printed, as a path from the repo root
yaml_path() {
  case $1 in
    /*) from_repo "$1" ;;
    *) in_project . "$1" ;;
  esac
}

yaml_check() {
  local f
  local -a workflows=() plain=()
  for f in "$@"; do
    if yaml_workflow "$f"; then
      workflows+=("$f")
    else
      plain+=("$f")
    fi
  done
  if ((${#workflows[@]})) && need actionlint "the GitHub Actions workflows"; then
    for f in "${workflows[@]}"; do
      yaml_actionlint "$f"
    done
  fi
  if ((${#plain[@]})); then
    yaml_lint "${plain[@]}"
  fi
}

# yaml_actionlint FILE: actionlint's one-line findings, one per line of output
yaml_actionlint() {
  local f=$1 rc=0
  bounded actionlint -no-color -oneline "$f" >"$(scratch actionlint.out)" 2>"$(scratch actionlint.err)" || rc=$?
  if ((rc == 124)); then
    note "actionlint ran out of time on $f"
    return 0
  fi
  if ((rc != 0 && rc != 1)); then
    note "actionlint failed on $f: $(head -1 "$(scratch actionlint.err)")"
    return 0
  fi
  # `path:line:col: message [rule]`
  sed -n -E 's|^(.+):([0-9]+):[0-9]+: (.*) \[([A-Za-z0-9_-]+)\]$|\1\t\2\t\4\t\3|p' "$(scratch actionlint.out)" |
    while IFS=$'\t' read -r path line rule msg; do
      finding warn "$(yaml_path "$path")" "$line" "actionlint-$rule" "$msg"
    done
}

# yaml_lint FILE...: yamllint's parsable findings, on the whole set at once
yaml_lint() {
  need yamllint "the YAML lint" || return 0
  local c rc=0
  local -a cfg=(-d relaxed)
  for c in .yamllint .yamllint.yaml .yamllint.yml; do
    if [[ -f $c ]]; then
      cfg=(-c "$c")
      break
    fi
  done
  bounded yamllint -f parsable "${cfg[@]}" "$@" >"$(scratch yamllint.out)" 2>"$(scratch yamllint.err)" || rc=$?
  if ((rc == 124)); then
    note "yamllint ran out of time"
    return 0
  fi
  if ((rc > 1)); then
    note "yamllint failed: $(head -1 "$(scratch yamllint.err)")"
    return 0
  fi
  # `path:line:col: [level] message (rule)`; only a file that doesn't parse is more than a warning
  sed -n -E 's#^(.+):([0-9]+):[0-9]+: \[(error|warning)\] (.*) \(([a-z0-9-]+)\)$#\1\t\2\t\4\t\5#p' "$(scratch yamllint.out)" |
    while IFS=$'\t' read -r path line msg rule; do
      if [[ $rule == syntax ]]; then
        finding error "$(yaml_path "$path")" "$line" "yamllint-$rule" "$msg"
      else
        finding warn "$(yaml_path "$path")" "$line" "yamllint-$rule" "$msg"
      fi
    done
}
