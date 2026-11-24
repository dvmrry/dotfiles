#!/usr/bin/env bash
# Tests for lang/tf.sh: findings as `path:line: tf/rule: message` for Terraform and OpenTofu files.
set -u
# shellcheck source=/dev/null # lib.sh, beside this file
. "$(dirname "$0")/lib.sh"

# Formatting: tofu fmt's canonical style needs no project config, and only what the change did is reported
r=$(t_repo fmt)
printf 'name="old"\n' >"$r/old.tfvars"
t_commit "$r"
printf 'name="a"\n' >"$r/new.tf"
printf 'name="old"\n# touched\n' >"$r/old.tfvars"
out=$(t_check "$r")
expect "a new unformatted file is a finding" '(^|'$'\n'')new\.tf:1: tf/format: not formatted; run agent-check fmt' "$out"
absent "a file unformatted at the base isn't this change's" 'old.tfvars:1: tf/format' "$out"
expect "fmt formats the new file only" '^formatted new\.tf$' "$(t_fmt "$r")"
absent "and leaves the old one alone" 'name = "old"' "$(cat "$r/old.tfvars")"
absent "a formatted file is clean" 'new.tf:1: tf/format' "$(t_check "$r")"

r=$(t_repo tofu-ext)
printf 'name="a"\n' >"$r/a.tofu"
expect "a .tofu file is formatted too" '(^|'$'\n'')a\.tofu:1: tf/format: ' "$(t_check "$r")"

# A file of another language isn't tf's to check
r=$(t_repo other)
printf 'export function g( x:number ){ return x }\n' >"$r/a.ts"
absent "a TypeScript file isn't checked as Terraform" 'tf/' "$(t_check "$r")"

if command -v tflint >/dev/null; then
  # Lint (tier 1): a finding on an added line counts; one already there doesn't
  r=$(t_repo tflint)
  printf '' >"$r/.tflint.hcl"
  printf 'terraform {\n  required_version = ">= 1.6"\n}\n' >"$r/main.tf"
  t_commit "$r"
  printf 'terraform {\n  required_version = ">= 1.6"\n}\n\nresource "aws_instance" "web" {\n  ami = "ami-123"\n}\n' >"$r/main.tf"
  out=$(t_check "$r" AGENT_CHECK_TIER=1)
  expect "a tflint warning on an added line is a finding" '(^|'$'\n'')main\.tf:5: tf/tflint-terraform_required_providers: ' "$out"
  expect "the message is tflint's own" '(^|'$'\n'')main\.tf:5: tf/tflint-terraform_required_providers: Missing version constraint for provider ' "$out"
  absent "without the level in front of it" 'Warning - ' "$out"
  absent "and without the rule after it, which is already the rule name" '(terraform_required_providers)' "$out"
  absent "tier 0 doesn't run tflint" 'tf/tflint' "$(t_check "$r")"
  absent "nor does tier 1 when tf's findings are only observed" 'tf/tflint' "$(t_check "$r" AGENT_CHECK_TIER=1 AGENT_CHECK_TIER1_LANGS=none)"

  t_commit "$r"
  printf 'terraform {\n  required_version = ">= 1.6"\n}\n\nresource "aws_instance" "web" {\n  ami = "ami-123"\n  instance_type = "t3.micro"\n}\n' >"$r/main.tf"
  absent "an old finding in a touched file stays quiet" 'main.tf:5: tf/tflint' "$(t_check "$r" AGENT_CHECK_TIER=1)"

  # A module directory is the project: findings are paths from the repo root
  r=$(t_repo subdir)
  mkdir -p "$r/modules/app"
  printf '' >"$r/modules/app/.tflint.hcl"
  printf 'resource "aws_instance" "web" {\n  ami = "ami-123"\n}\n' >"$r/modules/app/main.tf"
  expect "a new module's finding is pathed from the repo root" '(^|'$'\n'')modules/app/main\.tf:1: tf/tflint-terraform_required_version: ' "$(t_check "$r" AGENT_CHECK_TIER=1)"

  # Without a .tflint.hcl there's nothing to lint with, and without its plugins tflint can't run
  r=$(t_repo noconfig)
  printf 'resource "aws_instance" "web" {\n  ami = "ami-123"\n}\n' >"$r/main.tf"
  absent "a module directory without .tflint.hcl isn't linted" 'tf/tflint' "$(t_check "$r" AGENT_CHECK_TIER=1)"

  r=$(t_repo plugin)
  printf 'plugin "aws" {\n  enabled = true\n  version = "0.30.0"\n  source  = "github.com/terraform-linters/tflint-ruleset-aws"\n}\n' >"$r/.tflint.hcl"
  printf 'resource "aws_instance" "web" {\n  ami = "ami-123"\n}\n' >"$r/main.tf"
  absent "a module whose plugins aren't installed isn't linted" 'tf/tflint' "$(t_check "$r" AGENT_CHECK_TIER=1)"
  expect "and the notes say why, without running tflint --init" "plugins aren't installed" "$(t_notes)"
fi

t_done
