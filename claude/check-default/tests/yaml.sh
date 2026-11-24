#!/usr/bin/env bash
# Tests for lang/yaml.sh: yamllint on plain YAML, actionlint on GitHub Actions workflows, and the repo's own
# .yamllint config. Findings are `path:line: yaml/rule: message`.
set -u
# shellcheck source=/dev/null # lib.sh, beside this file
. "$(dirname "$0")/lib.sh"

# yamllint: a finding on an added line counts; one already there doesn't
r=$(t_repo lint)
printf 'a: 1\na: 2\n' >"$r/d.yaml"
t_commit "$r"
printf 'a: 1\na: 2\nb: 1\nb: 2\n' >"$r/d.yaml"
out=$(t_check "$r")
expect "a duplicate key on an added line is a finding" '(^|'$'\n'')d\.yaml:4: yaml/yamllint-key-duplicates: ' "$out"
absent "an old duplicate in a touched file stays quiet" 'd.yaml:2: yaml/yamllint-key-duplicates' "$out"

# A file that doesn't parse is an error, wherever the line came from
r=$(t_repo syntax)
printf 'key: [1,\n' >"$r/bad.yaml"
expect "a YAML syntax error is an error" '(^|'$'\n'')bad\.yaml:2: yaml/yamllint-syntax: ' "$(t_check "$r")"

# The repo's own config, when it has one
r=$(t_repo config)
printf 'extends: default\nrules:\n  truthy: enable\n' >"$r/.yamllint"
printf 'answer: yes\n' >"$r/t.yaml"
expect "the repo's .yamllint is used" '(^|'$'\n'')t\.yaml:1: yaml/yamllint-truthy: ' "$(t_check "$r")"

r=$(t_repo noconfig)
printf 'answer: yes\n' >"$r/t.yaml"
absent "without a .yamllint, relaxed allows yes/no" 'yaml/yamllint-truthy' "$(t_check "$r")"

# GitHub Actions workflows: actionlint, and nothing else
r=$(t_repo actionlint)
mkdir -p "$r/.github/workflows"
printf "name: ci\non:\n  issues:\n    types: [opened]\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo \${{ github.event.issue.title }}\n" >"$r/.github/workflows/ci.yml"
expect "actionlint reports an untrusted expression" '(^|'$'\n'')\.github/workflows/ci\.yml:9: yaml/actionlint-expression: ' "$(t_check "$r")"

r=$(t_repo workflow-not-yamllint)
mkdir -p "$r/.github/workflows"
printf 'extends: default\nrules:\n  truthy: enable\n' >"$r/.yamllint"
printf 'name: ci\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' >"$r/.github/workflows/ci.yml"
absent "a workflow isn't also linted with yamllint" 'yamllint' "$(t_check "$r")"

# Tier 1 adds nothing: yaml has no tier-1 steps
r=$(t_repo tier)
printf 'a: 1\na: 2\n' >"$r/d.yaml"
out1=$(t_check "$r" AGENT_CHECK_TIER=1)
expect "tier 1 reports the same findings" '(^|'$'\n'')d\.yaml:2: yaml/yamllint-key-duplicates: ' "$out1"
expect "and so does tier 1 with yaml's findings only observed" '(^|'$'\n'')d\.yaml:2: yaml/yamllint-key-duplicates: ' "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"

# Another language isn't yaml's
r=$(t_repo other)
printf 'export function g( x:number ){ return x }\n' >"$r/a.ts"
absent "a TypeScript file isn't checked by yaml" 'yaml/' "$(t_check "$r")"

t_done
