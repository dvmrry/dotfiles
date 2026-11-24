#!/usr/bin/env bash
# Tests for lang/go.sh: the finding lines (`path:line: go/rule: message`) the Go module reports, and their
# absence. Formatting is tier 0; the lint, the compiler and the tests are tier 1.
set -u
# shellcheck source=/dev/null # lib.sh, beside this file
. "$(dirname "$0")/lib.sh"

# Formatting: gofmt, and only what the change did
r=$(t_repo fmt)
printf 'module example.com/x\n\ngo 1.24\n' >"$r/go.mod"
printf 'package  p\n\nfunc legacy(x int) {\n}\n' >"$r/old.go"
t_commit "$r"
printf 'package  p\n\nfunc g(x int) {\n}\n' >"$r/new.go"
printf 'package  p\n\nfunc legacy(x int) {\n}\n// touched\n' >"$r/old.go"
out=$(t_check "$r")
expect "a new unformatted file is a finding" '(^|'$'\n'')new\.go:1: go/format: not formatted; run agent-check fmt' "$out"
absent "a file unformatted at the base isn't this change's" 'old.go:1: go/format' "$out"
expect "fmt formats the new file only" '^formatted new\.go$' "$(t_fmt "$r")"
absent "and leaves the old one alone" 'package p' "$(cat "$r/old.go")"
absent "a formatted file is clean" 'new.go:1: go/format' "$(t_check "$r")"

# gofumpt, when the project or the repo root asks for it; gofmt keeps what gofumpt would rewrite
if command -v gofumpt >/dev/null; then
  r=$(t_repo gofmt)
  printf 'module example.com/x\n\ngo 1.24\n' >"$r/go.mod"
  printf 'package p\n\nfunc f() {\n\n\treturn\n}\n' >"$r/a.go"
  absent "gofmt alone leaves a blank line after {" 'go/format' "$(t_check "$r")"

  r=$(t_repo gofumpt)
  printf 'module example.com/x\n\ngo 1.24\n' >"$r/go.mod"
  printf 'version: "2"\nformatters:\n  enable:\n    - gofumpt\n' >"$r/.golangci.yml"
  printf 'package p\n\nfunc f() {\n\n\treturn\n}\n' >"$r/a.go"
  expect "a project whose .golangci.yml mentions gofumpt is formatted with it" \
    '(^|'$'\n'')a\.go:4: go/format: ' "$(t_check "$r")"

  r=$(t_repo rootfumpt)
  printf 'all:\n\tgofumpt -l .\n' >"$r/Makefile"
  mkdir -p "$r/svc"
  printf 'module example.com/x/svc\n\ngo 1.24\n' >"$r/svc/go.mod"
  printf 'package svc\n\nfunc f() {\n\n\treturn\n}\n' >"$r/svc/a.go"
  expect "the repo root can mention gofumpt for a project below it" \
    '(^|'$'\n'')svc/a\.go:4: go/format: ' "$(t_check "$r")"
fi

# A .go file with no go.mod above it isn't a Go project's business
r=$(t_repo nomod)
printf 'package  p\n\nfunc g() {\n}\n' >"$r/a.go"
absent "a .go file with no go.mod isn't checked" 'go/' "$(t_check "$r")"
expect "and the notes say why" 'no go\.mod' "$(t_notes)"

# Not our language
r=$(t_repo wants)
printf 'module example.com/x\n\ngo 1.24\n' >"$r/go.mod"
printf 'package  p\n\nimport "fmt"\n\nfunc f() {}\n' >"$r/notes.txt"
absent "a file in another language isn't checked by the go module" 'go/' "$(t_check "$r" AGENT_CHECK_TIER=1)"

if command -v go >/dev/null && command -v golangci-lint >/dev/null; then
  # Lint: a finding on an added line counts, one already there doesn't
  r=$(t_repo lint)
  printf 'module example.com/x\n\ngo 1.24\n' >"$r/go.mod"
  mkdir -p "$r/pkg"
  printf 'package pkg\n\nimport "os"\n\nfunc Old() {\n\tos.Remove("old")\n}\n' >"$r/pkg/old.go"
  t_commit "$r"
  printf 'package pkg\n\nimport "os"\n\nfunc Old() {\n\tos.Remove("old")\n}\n\nfunc New() {\n\tos.Remove("new")\n}\n' >"$r/pkg/old.go"
  printf 'package pkg\n\nimport "os"\n\nfunc Fresh() {\n\tos.Remove("fresh")\n}\n' >"$r/pkg/fresh.go"
  out=$(t_check "$r" AGENT_CHECK_TIER=1)
  expect "an unchecked error on an added line is a finding" \
    '(^|'$'\n'')pkg/old\.go:10: go/golangci-errcheck: ' "$out"
  expect "and one in a new file" \
    '(^|'$'\n'')pkg/fresh\.go:6: go/golangci-errcheck: ' "$out"
  absent "an old finding in a touched file stays quiet" 'pkg/old.go:5:' "$out"
  absent "tier 0 doesn't run golangci-lint" 'go/golangci' "$(t_check "$r")"
  absent "nor does tier 1 when go's findings are only observed" \
    'go/golangci' "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"

  # The compiler: an unused import is a compile error, and counts wherever it is
  r=$(t_repo compile)
  printf 'module example.com/x\n\ngo 1.24\n' >"$r/go.mod"
  printf 'package p\n\nfunc F() {}\n' >"$r/a.go"
  t_commit "$r"
  printf 'package p\n\nimport "fmt"\n\nfunc F() {}\n' >"$r/a.go"
  expect "an unused import is a compile error" '(^|'$'\n'')a\.go:3: go/compile: ' "$(t_check "$r" AGENT_CHECK_TIER=1)"
  absent "tier 0 doesn't compile" 'go/compile' "$(t_check "$r")"
  absent "nor does tier 1 when go's findings are only observed" \
    'go/compile' "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"

  # Tests: a failing test reports where it failed
  r=$(t_repo tests)
  printf 'module example.com/x\n\ngo 1.24\n' >"$r/go.mod"
  mkdir -p "$r/pkg"
  printf 'package pkg\n\nfunc Add(a, b int) int { return a - b }\n' >"$r/pkg/a.go"
  printf 'package pkg\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) {\n\tif Add(1, 2) != 3 {\n\t\tt.Fatalf("Add(1, 2) = %%d", Add(1, 2))\n\t}\n}\n' >"$r/pkg/a_test.go"
  expect "tier 1 reports a failing test where it failed" \
    '(^|'$'\n'')pkg/a_test\.go:7: go/test: failed: TestAdd' "$(t_check "$r" AGENT_CHECK_TIER=1)"
  absent "tier 0 doesn't run the tests" 'go/test' "$(t_check "$r")"
  absent "nor does tier 1 when go's findings are only observed" \
    'go/test' "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"
fi

t_done
