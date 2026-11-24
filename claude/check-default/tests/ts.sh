#!/usr/bin/env bash
# Tests for lang/ts.sh: the pattern for every module's tests. Each case builds what it needs, runs check-default
# and checks the finding lines (`path:line: ts/rule: message`) or their absence.
set -u
# shellcheck source=/dev/null # lib.sh, beside this file
. "$(dirname "$0")/lib.sh"
t_needs biome

# Lint: a finding on an added line counts; one already there doesn't
r=$(t_repo lint)
printf 'const old = 1;\nexport const ok = 2;\n' >"$r/a.ts"
t_commit "$r"
printf 'const old = 1;\nexport const ok = 2;\nexport function f() {\n  const unused = 3;\n  return ok;\n}\n' >"$r/a.ts"
out=$(t_check "$r")
expect "an unused variable on an added line is a finding" '^a\.ts:4: ts/biome-noUnusedVariables: ' "$out"
absent "an old finding in a touched file stays quiet" 'a.ts:1:' "$out"

# Formatting: only where the project has a Biome config, and only what the change did
r=$(t_repo fmt)
printf '{\n  "formatter": { "indentStyle": "space", "indentWidth": 2 }\n}\n' >"$r/biome.json"
printf 'export function legacy( x:number ){ return x }\n' >"$r/old.ts"
t_commit "$r"
printf 'export function g( x:number ){ return x }\n' >"$r/new.ts"
printf 'export function legacy( x:number ){ return x }\n// touched\n' >"$r/old.ts"
out=$(t_check "$r")
expect "a new unformatted file is a finding" '(^|'$'\n'')new\.ts:1: ts/format: not formatted; run agent-check fmt' "$out"
absent "a file unformatted at the base isn't this change's" 'old.ts:1: ts/format' "$out"
expect "fmt formats the new file only" '^formatted new\.ts$' "$(t_fmt "$r")"
absent "and leaves the old one alone" 'export function legacy(x: number)' "$(cat "$r/old.ts")"
absent "a formatted file is clean" 'new.ts:1: ts/format' "$(t_check "$r")"

r=$(t_repo nostyle)
printf 'export function g( x:number ){ return x }\n' >"$r/a.ts"
absent "without a Biome config there's no style to check" 'ts/format' "$(t_check "$r")"

# The project's own tools: tier 0 doesn't run them, and leaves their job alone
r=$(t_repo pinned)
printf '{ "devDependencies": { "@biomejs/biome": "2.0.0" } }\n' >"$r/package.json"
printf 'export function f() {\n  const unused = 3;\n  return 1;\n}\n' >"$r/a.ts"
out=$(t_check "$r")
absent "a project that pins its own Biome isn't linted with ours" 'ts/biome' "$out"
expect "and the notes say why" 'skipped Biome in \.: the project pins its own' "$(t_notes)"

r=$(t_repo eslint)
printf 'export default [];\n' >"$r/eslint.config.js"
printf 'export function f() {\n  const unused = 3;\n  return 1;\n}\n' >"$r/a.ts"
absent "a project that lints with ESLint isn't linted with Biome" 'ts/biome' "$(t_check "$r")"

# Tier 1: type errors anywhere in the project, and failing tests
r=$(t_repo types)
printf '{ "compilerOptions": { "strict": true, "noEmit": true }, "include": ["*.ts"] }\n' >"$r/tsconfig.json"
printf 'export const n: number = 1;\n' >"$r/a.ts"
t_commit "$r"
printf 'export const s: number = "x";\n' >"$r/b.ts"
expect "tier 1 reports a type error" '(^|'$'\n'')b\.ts:1: ts/tsc-TS2322: ' "$(t_check "$r" AGENT_CHECK_TIER=1)"
absent "tier 0 doesn't run tsc" 'ts/tsc' "$(t_check "$r")"
absent "nor does tier 1 when ts's findings are only observed" 'ts/tsc' "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"

if command -v bun >/dev/null; then
  r=$(t_repo tests)
  printf '{ "name": "t" }\n' >"$r/package.json"
  printf '{ "lockfileVersion": 1, "workspaces": { "": { "name": "t" } } }\n' >"$r/bun.lock"
  printf 'import { expect, test } from "bun:test";\n\ntest("adds", () => {\n  expect(1 + 1).toBe(3);\n});\n' >"$r/math.test.ts"
  expect "tier 1 reports a failing test where it failed" '(^|'$'\n'')math\.test\.ts:4: ts/bun-test: failed: adds' "$(t_check "$r" AGENT_CHECK_TIER=1)"
fi

t_done
