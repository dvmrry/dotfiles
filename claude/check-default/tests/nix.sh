#!/usr/bin/env bash
# Tests for lang/nix.sh: findings as `path:line: nix/rule: message`, and their absence. nix has no tier-1 steps,
# so one case checks that tier 1 adds nothing over tier 0.
set -u
# shellcheck source=/dev/null # lib.sh, beside this file
. "$(dirname "$0")/lib.sh"
t_needs statix deadnix nixfmt

# t_same NAME A B: two runs reported the same findings
t_same() {
  if [[ $2 == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: got:
  $2
instead of:
  $3"
    fails=$((fails + 1))
  fi
}

# deadnix: an unused binding on an added line counts; the ones already there don't
r=$(t_repo deadnix)
printf '{ pkgs, lib, ... }:\nlet\n  oldUnused = 1;\nin {\n  x = pkgs.foo;\n}\n' >"$r/a.nix"
t_commit "$r"
printf '{ pkgs, lib, ... }:\nlet\n  oldUnused = 1;\n  newUnused = 2;\nin {\n  x = pkgs.foo;\n}\n' >"$r/a.nix"
out=$(t_check "$r")
expect "an unused let binding on an added line is a finding" \
  '(^|'$'\n'')a\.nix:4: nix/deadnix: Unused let binding: newUnused' "$out"
absent "an old unused binding in a touched file stays quiet" 'a.nix:3: nix/deadnix' "$out"
absent "and so does an old unused lambda argument" 'a.nix:1: nix/deadnix' "$out"

r=$(t_repo deadnix-arg)
printf '{ pkgs, lib, ... }:\n{\n  x = pkgs.foo;\n}\n' >"$r/b.nix"
expect "an unused lambda argument in a new file is a finding" \
  '(^|'$'\n'')b\.nix:1: nix/deadnix: Unused lambda pattern: lib' "$(t_check "$r")"

# statix: same, with the rule named for statix's own code
r=$(t_repo statix)
printf 'let\n  a = 1;\nin {\n  a = a;\n}\n' >"$r/c.nix"
expect "an assignment better written with inherit is a finding" \
  '(^|'$'\n'')c\.nix:4: nix/statix-3: This assignment is better written with' "$(t_check "$r")"

r=$(t_repo statix-old)
printf 'let\n  a = 1;\nin {\n  a = a;\n}\n' >"$r/c.nix"
t_commit "$r"
printf 'let\n  a = 1;\nin {\n  a = a;\n}\n# touched\n' >"$r/c.nix"
absent "an old statix finding in a touched file stays quiet" 'c.nix:4: nix/statix' "$(t_check "$r")"

# Formatting: only where the repo says it formats with nixfmt, and only what the change did
r=$(t_repo fmt)
printf '{\n  description = "nixfmt";\n  outputs = { self, nixpkgs }: { };\n}\n' >"$r/flake.nix"
printf '{a = 1;}\n' >"$r/old.nix"
t_commit "$r"
printf '{b = 2;}\n' >"$r/new.nix"
printf '{a = 1;}\n# touched\n' >"$r/old.nix"
out=$(t_check "$r")
expect "a new unformatted file is a finding" \
  '(^|'$'\n'')new\.nix:1: nix/format: not formatted; run agent-check fmt' "$out"
absent "a file unformatted at the base isn't this change's" 'old.nix:1: nix/format' "$out"
expect "fmt formats the new file only" '^formatted new\.nix$' "$(t_fmt "$r")"
absent "and leaves the old one alone" '{ a = 1; }' "$(cat "$r/old.nix")"
absent "a formatted file is clean" 'new.nix:1: nix/format' "$(t_check "$r")"

r=$(t_repo precommit)
printf 'repos:\n  - repo: https://github.com/cachix/pre-commit-hooks.nix\n    hooks:\n      - id: nixfmt\n' \
  >"$r/.pre-commit-config.yaml"
printf '{b = 2;}\n' >"$r/a.nix"
expect "a pre-commit config naming nixfmt is enough" \
  '(^|'$'\n'')a\.nix:1: nix/format: ' "$(t_check "$r")"

r=$(t_repo nostyle)
printf '{b = 2;}\n' >"$r/a.nix"
absent "a repo that doesn't mention nixfmt has no style to check" 'nix/format' "$(t_check "$r")"

# A file nixfmt can't parse is noted, not reported as a format finding
r=$(t_repo unparseable)
printf '{\n  description = "nixfmt";\n  outputs = { self, nixpkgs }: { };\n}\n' >"$r/flake.nix"
t_commit "$r"
printf '{ = ; }\n' >"$r/bad.nix"
out=$(t_check "$r")
absent "an unparseable file isn't reported as unformatted" 'bad.nix:1: nix/format' "$out"
expect "and the notes say what the formatter made of it" 'the formatter failed on bad\.nix' "$(t_notes)"

# No tier-1 steps: tier 1 finds no more than tier 0
r=$(t_repo tier1)
printf 'let\n  a = 1;\nin {\n  a = a;\n}\n' >"$r/a.nix"
out0=$(t_check "$r")
expect "tier 0 runs the lint" '(^|'$'\n'')a\.nix:4: nix/statix-3: ' "$out0"
t_same "tier 1 adds nothing" "$out0" "$(t_check "$r" AGENT_CHECK_TIER=1)"
t_same "nor does tier 1 when nix's findings are only observed" \
  "$out0" "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"

# Another language is not ours to check
r=$(t_repo other)
printf 'let a = 1; in { a = a; }\n' >"$r/a.sh"
out=$(t_check "$r")
absent "a shell file isn't linted as Nix" 'nix/' "$out"

# A file statix can't parse is an error, wherever it is, not a lint warning
r=$(t_repo nixsyntax)
printf '{ a = 1; }\n' >"$r/ok.nix"
t_commit "$r"
printf '{ a = ;\n' >"$r/ok.nix"
expect "a file that doesn't parse is nix/statix-syntax" '(^|'$'\n'')ok\.nix:1: nix/statix-syntax: ' "$(t_check "$r")"

t_done
