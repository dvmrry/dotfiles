#!/usr/bin/env bash
# Tests for lang/common.sh: secrets, merge markers and JSON, on any file.
set -u
# shellcheck source=/dev/null # lib.sh, beside this file
. "$(dirname "$0")/lib.sh"

r=$(t_repo common)
printf '{ "a": 1 }\n' >"$r/ok.json"
printf '{ "a": 1, // a comment\n}\n' >"$r/jsonc.json"
printf 'line\n' >"$r/notes.txt"
t_commit "$r"

# Built at run time, so this file holds no secret for the repo's own gitleaks hook to find
tok=ghp_$(head -c 400 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 36)
printf 'token = "%s"\n' "$tok" >"$r/creds.txt"
out=$(t_check "$r")
expect "a secret is a finding" '(^|'$'\n'')creds\.txt:1: common/gitleaks: github-pat looks like a secret' "$out"
absent "and the secret itself isn't repeated" "$tok" "$out"
rm "$r/creds.txt"

printf 'line\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> other\n' >"$r/notes.txt"
out=$(t_check "$r")
expect "an added conflict marker is a finding" '(^|'$'\n'')notes\.txt:2: common/merge-marker: ' "$out"
expect "both ends of it" '(^|'$'\n'')notes\.txt:6: common/merge-marker: ' "$out"
git -C "$r" checkout -q -- notes.txt

printf '{ "a": 1,\n}\n' >"$r/ok.json"
expect "JSON that parsed at the base and doesn't now is a finding" '(^|'$'\n'')ok\.json:[0-9]+: common/json: ' "$(t_check "$r")"
git -C "$r" checkout -q -- ok.json
printf '{ "a": 2, // still a comment\n}\n' >"$r/jsonc.json"
absent "a file that never parsed (JSONC) stays quiet" 'jsonc.json' "$(t_check "$r")"
printf '{ "compilerOptions": { }, // comments are fine here\n}\n' >"$r/tsconfig.json"
absent "tsconfig.json is JSONC by design" 'tsconfig.json' "$(t_check "$r")"

t_done
