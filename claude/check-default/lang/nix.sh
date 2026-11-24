# shellcheck shell=bash
# nix: Nix files, for a repo like this one.
#   format (tier 0): nixfmt, and only where the repo says it formats with nixfmt - one of flake.nix,
#     .pre-commit-config.yaml, treefmt.toml or treefmt.nix at the repo root mentions it. Without that there's no
#     project style to follow.
#   lint (tier 0): statix and deadnix, per changed file. Both are lint, so their findings are warns: only on the
#     lines the change adds, or anywhere in a new file.
#   No tier-1 steps: nothing here evaluates a flake or builds anything.

nix_wants() { [[ $1 =~ \.nix$ ]]; }

# nix_repo_formats: the repo says it formats its Nix with nixfmt
nix_repo_formats() {
  local f
  for f in flake.nix .pre-commit-config.yaml treefmt.toml treefmt.nix; do
    grep -qs nixfmt "$f" && return 0
  done
  return 1
}

nix_format() {
  nix_repo_formats || return 3
  need nixfmt "nix formatting" || return 3
  nixfmt -
}

# nix_statix FILE: statix's findings, one per line: `path>line:col:severity:code:message`; exit 1 when it found any
nix_statix() {
  local f=$1 rc=0 path line sev code msg
  need statix "the statix lint" || return 0
  bounded statix check -o errfmt "$f" >"$(scratch statix.out)" 2>"$(scratch statix.err)" || rc=$?
  if ((rc == 124)); then
    note "statix ran out of time in $f"
    return 0
  fi
  if ((rc != 0 && rc != 1)); then
    note "statix failed on $f: $(head -1 "$(scratch statix.err)")"
    return 0
  fi
  # Severity E is a file statix can't parse (code 0): an error wherever it is, like other modules' syntax errors
  sed -n -E 's/^(.*)>([0-9]+):[0-9]+:([A-Za-z]+):([0-9]+):(.*)$/\1\t\2\t\3\t\4\t\5/p' "$(scratch statix.out)" |
    while IFS=$'\t' read -r path line sev code msg; do
      if [[ $sev == E ]]; then
        finding error "$(from_repo "$path")" "$line" statix-syntax "$msg"
      else
        finding warn "$(from_repo "$path")" "$line" "statix-$code" "$msg"
      fi
    done
}

# nix_deadnix FILE: deadnix's JSON, {"file":...,"results":[{"line":N,"column":N,"message":...}]}; exit 0 even
# when it found something. An unused lambda argument (`lib` in `{ pkgs, lib, ... }:`) is a result like any other.
nix_deadnix() {
  local f=$1 rc=0 line msg bad
  need deadnix "the deadnix lint" || return 0
  bounded deadnix --output-format json "$f" >"$(scratch deadnix.out)" 2>"$(scratch deadnix.err)" || rc=$?
  if ((rc == 124)); then
    note "deadnix ran out of time in $f"
    return 0
  fi
  if ((rc != 0)); then
    note "deadnix failed on $f: $(head -1 "$(scratch deadnix.err)")"
    return 0
  fi
  # a result with no line is deadnix failing to parse the file, which still exits 0
  bad=$(jq -r '[.results[]? | select(.line == null) | .message][0] // empty' "$(scratch deadnix.out)")
  [[ -z $bad ]] || note "deadnix could not parse $f: $bad"
  jq -r '.results[]? | select(.line != null) | [(.line | tostring), .message] | @tsv' "$(scratch deadnix.out)" |
    while IFS=$'\t' read -r line msg; do
      finding warn "$(from_repo "$f")" "$line" deadnix "$msg"
    done
}

nix_check() {
  local f
  if nix_repo_formats; then
    need nixfmt "the format check" || true
  fi
  check_format "$@"
  for f in "$@"; do
    nix_statix "$f"
    nix_deadnix "$f"
  done
}
