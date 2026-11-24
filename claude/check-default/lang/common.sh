# shellcheck shell=bash
# common: every changed file, whatever its language.
#   gitleaks: anything that looks like a secret (always blocks; see ../modes)
#   merge-marker: an unresolved conflict marker on an added line
#   json: a .json file that doesn't parse, where it parsed at the base or is new. Files with comments (JSONC)
#     never parsed, so they stay quiet; tsconfig, jsconfig, devcontainer and editor files are JSONC by design.

common_wants() { return 0; }

common_check() {
  local f line rule
  if need gitleaks "the secret scan"; then
    for f in "$@"; do
      gitleaks dir --no-banner --redact --log-level error --report-format json --report-path - "$f" 2>/dev/null |
        jq -r '.[]? | [.StartLine, .RuleID] | @tsv' |
        while IFS=$'\t' read -r line rule; do
          finding error "$f" "$line" gitleaks "$rule looks like a secret; remove it, never commit it"
        done
    done
  fi
  for f in "$@"; do
    grep -n -E '^(<<<<<<<|>>>>>>>)( |$)' "$f" 2>/dev/null | cut -d: -f1 |
      while read -r line; do
        finding warn "$f" "$line" merge-marker "unresolved merge conflict marker"
      done
  done
  for f in "$@"; do
    if [[ $f == *.json ]]; then common_json "$f"; fi
  done
}

common_json() {
  local f=$1 err line
  case $f in
    tsconfig*.json | */tsconfig*.json | jsconfig*.json | */jsconfig*.json | .vscode/* | */.vscode/* | *devcontainer.json) return 0 ;;
  esac
  err=$(jq empty "$f" 2>&1 >/dev/null) && return 0
  if at_base "$f" >"$(scratch base.json)" && ! jq empty "$(scratch base.json)" >/dev/null 2>&1; then
    return 0
  fi
  line=$(sed -n -E 's/.* at line ([0-9]+),.*/\1/p' <<<"$err" | head -1)
  finding error "$f" "${line:-1}" json "doesn't parse: ${err%%$'\n'*}"
}
