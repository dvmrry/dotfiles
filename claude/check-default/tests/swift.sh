#!/usr/bin/env bash
# Tests for lang/swift.sh: format and lint only, and no tier 1 at all. Each case builds a small repo, runs
# check-default on it and checks the finding lines (`path:line: swift/rule: message`) or their absence.
set -u
# shellcheck source=/dev/null # lib.sh, beside this file
. "$(dirname "$0")/lib.sh"

# t_same NAME WANT GOT: the same findings, so a tier that should add nothing does add nothing
t_same() {
  if [[ $3 == "$2" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: got: ${3:-<nothing>} want: ${2:-<nothing>}"
    fails=$((fails + 1))
  fi
}

# swift-format's lint: a finding on an added line counts; one already there doesn't
r=$(t_repo fmtlint)
printf '{ "version": 1, "indentation": { "spaces": 2 } }\n' >"$r/.swift-format"
printf 'let  a = 1\n' >"$r/a.swift"
t_commit "$r"
printf 'let  a = 1\nlet  b = 2\n' >"$r/a.swift"
out=$(t_check "$r")
expect "a spacing finding on an added line is a finding" '(^|'$'\n'')a\.swift:2: swift/swift-format-Spacing: ' "$out"
absent "an old finding in a touched file stays quiet" 'a.swift:1: swift/swift-format-Spacing' "$out"

# SwiftLint's lint: the same, with the rule id from the end of its line
r=$(t_repo swiftlint)
printf 'only_rules: [colon]\n' >"$r/.swiftlint.yml"
printf 'let a:Int = 1\n' >"$r/a.swift"
t_commit "$r"
printf 'let a:Int = 1\nlet b:Int = 2\n' >"$r/a.swift"
out=$(t_check "$r")
expect "a colon finding on an added line is a finding" '(^|'$'\n'')a\.swift:2: swift/swiftlint-colon: ' "$out"
absent "an old colon finding stays quiet" 'a.swift:1: swift/swiftlint-colon' "$out"

# Formatting: only where the project has a .swift-format, and only what the change did
r=$(t_repo fmt)
printf '{ "version": 1, "indentation": { "spaces": 2 } }\n' >"$r/.swift-format"
printf 'func legacy( x:Int ){ return x }\n' >"$r/old.swift"
t_commit "$r"
printf 'func g( y:Int ){ return y }\n' >"$r/new.swift"
printf 'func legacy( x:Int ){ return x }\n// touched\n' >"$r/old.swift"
out=$(t_check "$r")
expect "a new unformatted file is a finding" '(^|'$'\n'')new\.swift:1: swift/format: not formatted; run agent-check fmt' "$out"
absent "a file unformatted at the base isn't this change's" 'old.swift:1: swift/format' "$out"
expect "fmt formats the new file only" '^formatted new\.swift$' "$(t_fmt "$r")"
absent "and leaves the old one alone" 'func legacy(x: Int)' "$(cat "$r/old.swift")"
absent "a formatted file is clean" 'new.swift:1: swift/format' "$(t_check "$r")"

# With neither a .swift-format nor a .swiftlint.yml there's nothing of swift's to report
r=$(t_repo noconfig)
printf 'func g( y:Int ){ return y }\n' >"$r/a.swift"
absent "without a config there's no style to check" 'swift/format' "$(t_check "$r")"
absent "and no lint either" 'swift/' "$(t_check "$r")"

# No tier 1: this module never builds, type checks or runs tests, whatever the tier
r=$(t_repo tier1)
printf '{ "version": 1, "indentation": { "spaces": 2 } }\n' >"$r/.swift-format"
printf 'only_rules: [colon]\n' >"$r/.swiftlint.yml"
printf 'let a = 1\n' >"$r/a.swift"
t_commit "$r"
printf 'let a = 1\nlet  b:Int = 2\n' >"$r/a.swift"
out=$(t_check "$r")
expect "tier 0 reports the lint findings" '(^|'$'\n'')a\.swift:2: swift/swift-format-Spacing: ' "$out"
t_same "tier 1 adds nothing to them" "$out" "$(t_check "$r" AGENT_CHECK_TIER=1)"
t_same "nor does tier 1 when swift's findings are only observed" "$out" \
  "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"

# A file in another language isn't the module's, whatever its config
r=$(t_repo other)
printf '{ "version": 1, "indentation": { "spaces": 2 } }\n' >"$r/.swift-format"
printf 'only_rules: [colon]\n' >"$r/.swiftlint.yml"
printf 'let  a:Int = 1\n' >"$r/a.m"
absent "an Objective-C file isn't checked as Swift" 'swift/' "$(t_check "$r")"

t_done
