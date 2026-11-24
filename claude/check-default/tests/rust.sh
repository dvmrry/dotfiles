#!/usr/bin/env bash
# Tests for lang/rust.sh: rustfmt with the project's edition, cargo clippy and cargo test at tier 1.
set -u
# shellcheck source=/dev/null # lib.sh, beside this file
. "$(dirname "$0")/lib.sh"

# cargo_manifest [EDITION]: a Cargo.toml for a test project
cargo_manifest() {
  printf '[package]\nname = "t"\nversion = "0.1.0"\nedition = "%s"\n' "${1:-2021}"
}

# Formatting: rustfmt with the project's edition, and only what the change did
r=$(t_repo fmt)
cargo_manifest >"$r/Cargo.toml"
mkdir -p "$r/src"
printf 'pub fn legacy( x: i32 ) -> i32 { x }\n' >"$r/src/legacy.rs"
t_commit "$r"
printf 'pub fn fresh( x: i32 ) -> i32 { x }\n' >"$r/src/fresh.rs"
printf 'pub fn legacy( x: i32 ) -> i32 { x }\n// touched\n' >"$r/src/legacy.rs"
out=$(t_check "$r")
expect "a new unformatted file is a finding" '(^|'$'\n'')src/fresh\.rs:1: rust/format: not formatted; run agent-check fmt' "$out"
absent "a file unformatted at the base isn't this change's" 'src/legacy.rs:1: rust/format' "$out"
expect "fmt formats the new file only" '^formatted src/fresh\.rs$' "$(t_fmt "$r")"
absent "and leaves the old one alone" 'pub fn legacy(x: i32)' "$(cat "$r/src/legacy.rs")"
absent "a formatted file is clean" 'rust/format' "$(t_check "$r")"

# The edition comes from Cargo.toml: `try` is only an identifier in 2015, so 2021 wouldn't even parse it
r=$(t_repo edition)
cargo_manifest 2015 >"$r/Cargo.toml"
printf 'pub fn try( ) -> i32 { 1 }\n' >"$r/lib.rs"
expect "a 2015 project formats with --edition 2015" '(^|'$'\n'')lib\.rs:1: rust/format: ' "$(t_check "$r")"

# The same, from the command line rustfmt is given: a wrapper in front of the real one records its arguments
bin=$(mktemp -d)
log=$bin/args
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexec %s "$@"\n' "$log" "$(command -v rustfmt)" >"$bin/rustfmt"
chmod +x "$bin/rustfmt"
r=$(t_repo edition18)
cargo_manifest 2018 >"$r/Cargo.toml"
printf 'pub fn fresh( x: i32 ) -> i32 { x }\n' >"$r/fresh.rs"
out=$(t_check "$r" PATH="$bin:$PATH")
expect "a 2018 project formats with --edition 2018" 'edition 2018' "$(cat "$log")"
expect "and formats through the wrapper all the same" '(^|'$'\n'')fresh\.rs:1: rust/format: ' "$out"
rm -rf "$bin"

# A .rs file that isn't part of a cargo project is left alone
r=$(t_repo noproject)
printf 'fn f() {}\n' >"$r/a.rs"
out=$(t_check "$r" AGENT_CHECK_TIER=1)
absent "a .rs file with no Cargo.toml above it gives no finding" 'rust/' "$out"
expect "and the notes say why" 'no Cargo\.toml' "$(t_notes)"

# Tier 1: clippy warnings on the lines the change added
r=$(t_repo clippy)
cargo_manifest >"$r/Cargo.toml"
mkdir -p "$r/src"
printf 'pub fn old() {\n    let unused = 1;\n}\n' >"$r/src/lib.rs"
t_commit "$r"
printf '\npub fn needless_return(x: i32) -> i32 {\n    return x;\n}\n\npub fn fresh() {\n    let unused = 3;\n}\n' >>"$r/src/lib.rs"
out=$(t_check "$r" AGENT_CHECK_TIER=1)
expect "a clippy lint on an added line is a finding" '(^|'$'\n'')src/lib\.rs:6: rust/clippy-needless_return: ' "$out"
absent "an old warning in a touched file stays quiet" 'src/lib.rs:2: rust/rustc-unused_variables' "$out"
# cargo prints each diagnostic once per target; only the added line (10) counts, and once
expect "an unused variable on an added line is a finding, once" '^1$' \
  "$(grep -c 'src/lib.rs:10: rust/rustc-unused_variables: ' <<<"$out")"
absent "tier 0 doesn't run clippy" 'rust/clippy-needless_return' "$(t_check "$r")"
absent "nor does tier 1 when rust's findings are only observed" 'rust/clippy-needless_return' \
  "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"

# A type error counts wherever it is, and the tests aren't run after one
r=$(t_repo types)
cargo_manifest >"$r/Cargo.toml"
mkdir -p "$r/src"
printf 'pub fn broken() -> i32 {\n    let n: i32 = "x";\n    n\n}\n' >"$r/src/lib.rs"
t_commit "$r"
printf 'pub fn ok() {}\n' >"$r/src/extra.rs"
out=$(t_check "$r" AGENT_CHECK_TIER=1)
expect "a type error on an old line is still a finding" '(^|'$'\n'')src/lib\.rs:2: rust/rustc-E0308: ' "$out"
absent "and cargo test isn't run after an error" 'rust/test' "$out"
absent "tier 0 doesn't run cargo clippy" 'rust/rustc' "$(t_check "$r")"
absent "nor does tier 1 when rust's findings are only observed" 'rust/rustc' \
  "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"

# A failing test is reported where it panicked
r=$(t_repo test)
cargo_manifest >"$r/Cargo.toml"
mkdir -p "$r/src"
printf 'pub fn adds(a: i32, b: i32) -> i32 {\n    a + b\n}\n\n#[cfg(test)]\nmod tests {\n    use super::adds;\n\n    #[test]\n    fn adds_wrong() {\n        assert_eq!(adds(1, 1), 3);\n    }\n}\n' >"$r/src/lib.rs"
out=$(t_check "$r" AGENT_CHECK_TIER=1)
expect "a panicking test is a finding at the panic" '(^|'$'\n'')src/lib\.rs:11: rust/test: failed: tests::adds_wrong' "$out"
absent "tier 0 doesn't run cargo test" 'rust/test' "$(t_check "$r")"
absent "nor does tier 1 when rust's findings are only observed" 'rust/test' \
  "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"

# Another language isn't ours
r=$(t_repo other)
printf 'export const ok = 1;\n' >"$r/a.ts"
absent "a TypeScript file isn't Rust's to check" 'rust/' "$(t_check "$r" AGENT_CHECK_TIER=1)"

# A workspace: cargo runs at the workspace root and names files relative to it, and a Cargo.lock is never rewritten
r=$(t_repo workspace)
printf '[workspace]\nmembers = ["crates/a"]\nresolver = "2"\n' >"$r/Cargo.toml"
mkdir -p "$r/crates/a/src"
printf '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n' >"$r/crates/a/Cargo.toml"
printf 'pub fn old() -> i32 {\n    1\n}\n' >"$r/crates/a/src/lib.rs"
(cd "$r" && cargo generate-lockfile -q 2>/dev/null)
t_commit "$r"
printf 'pub fn old() -> i32 {\n    let spare = 2;\n    1\n}\n' >"$r/crates/a/src/lib.rs"
out=$(t_check "$r" AGENT_CHECK_TIER=1)
expect "a member crate's finding is named from the repo root" '(^|'$'\n'')crates/a/src/lib\.rs:2: rust/rustc-unused_variables: ' "$out"
absent "and its path isn't doubled" 'crates/a/crates/a' "$out"
expect "the committed Cargo.lock is untouched" '^$' "$(git -C "$r" status --porcelain Cargo.lock)"

t_done
