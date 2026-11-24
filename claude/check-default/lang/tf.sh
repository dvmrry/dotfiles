# shellcheck shell=bash
# tf: Terraform and OpenTofu (.tf, .tofu, .tfvars). A Terraform module is a directory, so the directory a file
#   sits in is its project.
#   format (tier 0): tofu fmt -, whose canonical style needs no project config.
#   lint (tier 1): tflint --format=compact, once per changed module directory that has a .tflint.hcl.
#   Nothing builds or tests: tofu validate needs tofu init, which downloads providers.

tf_wants() { [[ $1 =~ \.(tf|tofu|tfvars)$ ]]; }

# tf_plain: the colour codes tofu and tflint put in their output, gone
tf_plain() { sed -e $'s/\033\\[[0-9;]*m//g'; }

tf_format() {
  local rc=0
  need tofu "tofu fmt" || return 3
  tofu fmt - >"$(scratch tf.fmt)" 2>"$(scratch tf.err)" || rc=$?
  cat "$(scratch tf.fmt)"
  # tofu frames its errors in box-drawing lines; the note (lib.sh's first stderr line) wants the Error: line
  tf_plain <"$(scratch tf.err)" | sed -E 's/^[│╷╵ ]+//' | grep -m1 -E 'Error' >&2
  return $rc
}

tf_check() {
  local f d rc
  local -A dirs=()
  for f in "$@"; do
    d=$(dirname "$f")
    dirs[$d]+="$f"$'\n'
  done
  check_format "$@"

  tier1 || return 0
  need tflint "the Terraform lint" || return 0

  for d in "${!dirs[@]}"; do
    [[ -f $d/.tflint.hcl ]] || continue
    rc=0
    (cd "$d" && bounded tflint --format=compact) >"$(scratch tflint.out)" 2>"$(scratch tflint.err)" || rc=$?
    if ((rc == 124)); then
      note "tflint ran out of time in $d"
      continue
    fi
    # 2 means it found issues, which is the point of running it; anything else is the tool failing
    if ((rc != 0 && rc != 2)); then
      if grep -qiE 'plugin .*not found' "$(scratch tflint.err)"; then
        note "skipped tflint in $d: its plugins aren't installed, and we don't run tflint --init"
      else
        note "skipped tflint in $d: $(tf_plain <"$(scratch tflint.err)" | head -1)"
      fi
      continue
    fi
    # file:line:col: Level - message (rule), with file relative to the module directory, plus a summary line
    sed -n -E 's|^([^:]+):([0-9]+):[0-9]+: [A-Za-z]+ - (.*) \(([a-zA-Z0-9_-]+)\)$|\1\t\2\t\3\t\4|p' "$(scratch tflint.out)" |
      while IFS=$'\t' read -r path line msg rule; do
        finding warn "$(in_project "$d" "$path")" "$line" "tflint-$rule" "$msg"
      done
  done
}
