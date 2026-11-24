#!/usr/bin/env bash
# Tests for lang/py.sh: ruff's lint findings on the lines a change adds, its format check where the project has a
# ruff config, and what it leaves alone (another language, an old line, a project without a config).
set -u
# shellcheck source=/dev/null # lib.sh, beside this file
. "$(dirname "$0")/lib.sh"
t_needs ruff

# Lint: a finding on an added line counts; one already there doesn't
r=$(t_repo lint)
printf 'import os\n\n\ndef f(x):\n    return x\n' >"$r/a.py"
t_commit "$r"
printf 'import os\n\n\ndef f(x):\n    y = 2\n    return x\n' >"$r/a.py"
out=$(t_check "$r")
expect "an unused local on an added line is a finding" '(^|'$'\n'')a\.py:5: py/ruff-F841: ' "$out"
absent "an old finding in a touched file stays quiet" 'a.py:1:' "$out"

r=$(t_repo f401)
printf 'print(1)\n' >"$r/b.py"
t_commit "$r"
printf 'import os\nprint(1)\n' >"$r/b.py"
expect "an unused import on an added line is a finding" '(^|'$'\n'')b\.py:1: py/ruff-F401: ' "$(t_check "$r")"

# A file that doesn't parse is an error, wherever it is
r=$(t_repo syntax)
printf 'def f(:\n    pass\n' >"$r/bad.py"
expect "a file that doesn't parse is an error" '(^|'$'\n'')bad\.py:1: py/ruff-syntax: ' "$(t_check "$r")"

# What's linted is the project's business: its own ruff config decides, and a user-level one doesn't
r=$(t_repo ruffconfig)
printf 'lint.select = ["I"]\n' >"$r/ruff.toml"
printf 'import sys\nimport os\n\nprint(sys)\n' >"$r/sort.py"
out=$(t_check "$r")
expect "a project that selects I flags unsorted imports" '(^|'$'\n'')sort\.py:1: py/ruff-I001: ' "$out"
absent "and is checked for nothing else" 'py/ruff-F401' "$out"

mkdir -p "$XDG_CONFIG_HOME/ruff"
printf 'lint.select = ["D"]\n' >"$XDG_CONFIG_HOME/ruff/ruff.toml"
r=$(t_repo noconfig)
printf 'import os\n\n\ndef f():\n    return 1\n' >"$r/doc.py"
out=$(t_check "$r")
expect "a project with no ruff config is still linted with ruff's own defaults" '(^|'$'\n'')doc\.py:1: py/ruff-F401: ' "$out"
absent "but not with a user-level config's rules" 'py/ruff-D103' "$out"
rm -rf "$XDG_CONFIG_HOME/ruff"

# An extensionless script is Python by its shebang, and nothing else is
r=$(t_repo shebang)
printf '#!/usr/bin/env python3\nimport os\n\nprint(1)\n' >"$r/build"
chmod +x "$r/build"
expect "a script with a python shebang is checked" '(^|'$'\n'')build:2: py/ruff-F401: ' "$(t_check "$r")"

r=$(t_repo noext)
printf 'all:\n\techo hi\n' >"$r/Makefile"
absent "an extensionless file without one isn't" 'py/' "$(t_check "$r" AGENT_CHECK_LANGS=py)"

r=$(t_repo otherlang)
printf 'export function f() {\n  const unused = 3;\n  return 1;\n}\n' >"$r/a.js"
printf 'import os\nprint(1)\n' >"$r/a.py"
out=$(t_check "$r" AGENT_CHECK_LANGS=py)
expect "the .py file of the two is checked" '(^|'$'\n'')a\.py:1: py/ruff-F401: ' "$out"
absent "the .js file isn't" 'a.js' "$out"

# Formatting: only where the project has a ruff config, and only what the change did
r=$(t_repo fmt)
printf 'line-length = 88\n' >"$r/ruff.toml"
printf 'def legacy( a ):\n  return a\n' >"$r/old.py"
t_commit "$r"
printf 'def g( b ):\n  return b\n' >"$r/new.py"
printf 'def legacy( a ):\n  return a\n# touched\n' >"$r/old.py"
out=$(t_check "$r")
expect "a new unformatted file is a finding" '(^|'$'\n'')new\.py:1: py/format: not formatted; run agent-check fmt' "$out"
absent "a file unformatted at the base isn't this change's" 'old.py:1: py/format' "$out"
expect "fmt formats the new file only" '^formatted new\.py$' "$(t_fmt "$r")"
absent "and leaves the old one alone" 'def legacy(a):' "$(cat "$r/old.py")"
absent "a formatted file is clean" 'new.py:1: py/format' "$(t_check "$r")"

r=$(t_repo nostyle)
printf 'def g( b ):\n  return b\n' >"$r/a.py"
absent "without a ruff config there's no style to check" 'py/format' "$(t_check "$r")"

# Nothing of ruff's is left in the repo: --no-cache, and no build output
expect "ruff left no cache behind" '' "$(find "$r" -name .ruff_cache)"

# No tier-1 steps: pytest needs the project's own environment, so it stays in a repo's own check-fast
r=$(t_repo tier1)
printf 'import os\nprint(1)\n' >"$r/a.py"
out=$(t_check "$r" AGENT_CHECK_TIER=1)
expect "tier 1 lints the same as tier 0" '(^|'$'\n'')a\.py:1: py/ruff-F401: ' "$out"
absent "and runs nothing else" 'pytest' "$out
$(t_notes)"

t_done
