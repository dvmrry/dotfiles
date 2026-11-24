#!/usr/bin/env bash
# Tests for lang/sh.sh: findings as `path:line: sh/rule: message`, and their absence. ShellCheck and shfmt are
# tier-0 tools, so these need them on PATH; there are no tier-1 steps to test.
set -u
# shellcheck source=/dev/null # lib.sh, beside this file
. "$(dirname "$0")/lib.sh"
t_needs shellcheck shfmt

# Lint: a finding on an added line counts; one already there doesn't
r=$(t_repo lint)
printf '#!/usr/bin/env bash\nold=1\necho hi\n' >"$r/a.sh"
t_commit "$r"
printf '#!/usr/bin/env bash\nold=1\necho hi\nunused=3\n' >"$r/a.sh"
out=$(t_check "$r")
expect "an unused variable on an added line is a finding" '(^|'$'\n'')a\.sh:4: sh/shellcheck-SC2034: ' "$out"
absent "an old finding in a touched file stays quiet" 'a.sh:2: sh/shellcheck-SC2034' "$out"

# Formatting: only where the repo has an .editorconfig, and only what the change did
r=$(t_repo fmt)
printf '[*.sh]\nindent_style = space\nindent_size = 2\n' >"$r/.editorconfig"
printf 'f() {\n\told=1\n\techo hi\n}\n' >"$r/old.sh"
t_commit "$r"
printf 'g() {\n\tnew=1\n\techo hi\n}\n' >"$r/new.sh"
printf 'f() {\n\told=1\n\techo hi\n}\n# touched\n' >"$r/old.sh"
out=$(t_check "$r")
expect "a new unformatted file is a finding" '(^|'$'\n'')new\.sh:2: sh/format: not formatted; run agent-check fmt' "$out"
absent "a file unformatted at the base isn't this change's" 'old.sh:2: sh/format' "$out"
expect "fmt formats the new file only" '^formatted new\.sh$' "$(t_fmt "$r")"
absent "and leaves the old one alone" '  old=1' "$(cat "$r/old.sh")"
absent "a formatted file is clean" 'new.sh:2: sh/format' "$(t_check "$r")"

r=$(t_repo nostyle)
printf 'g() {\n\tnew=1\n\techo hi\n}\n' >"$r/a.sh"
absent "without an .editorconfig there's no style to check" 'sh/format' "$(t_check "$r")"

# Which files are ours: bash and sh only; ShellCheck can't read zsh
r=$(t_repo wants)
mkdir -p "$r/scripts"
printf '#!/usr/bin/env bash\nunused=1\n' >"$r/scripts/tool"
printf '#!/usr/bin/env bash\nunused=2\n' >"$r/b.bash"
printf '#!/bin/zsh\nunused=1\n' >"$r/scripts/ztool"
printf '#!/usr/bin/env zsh\nunused=1\n' >"$r/z.sh"
printf 'const unused = 1;\n' >"$r/a.ts"
out=$(t_check "$r")
expect "an extensionless script with a bash shebang is checked" '(^|'$'\n'')scripts/tool:2: sh/shellcheck-SC2034: ' "$out"
expect "so is a .bash file" '(^|'$'\n'')b\.bash:2: sh/shellcheck-SC2034: ' "$out"
absent "a zsh script isn't" 'ztool' "$out"
absent "nor a .sh file whose shebang is zsh" 'z.sh' "$out"
absent "another language isn't checked by this module" 'a.ts:1: sh/' "$out"

t_done
