# shellcheck shell=bash
# sh: the repo's own shell scripts, bash and POSIX sh.
#   lint (tier 0): ShellCheck over the changed files at once, warnings and above. Only bash and sh: ShellCheck
#     can't read zsh, fish or ksh, so a script whose shebang names one of those isn't ours to check.
#   format (tier 0): shfmt, and only where the repo root has an .editorconfig to follow. Without one shfmt
#     indents with tabs, which is a style no project here declared.
#   No tier-1 steps: nothing here builds, type checks or runs tests.

# sh_bash_shebang FILE: its first line is a bash or sh shebang
sh_bash_shebang() {
  head -1 "$1" 2>/dev/null | grep -qE '^#!(/usr)?/bin/(env[[:space:]]+)?(bash|sh)([[:space:]]|$)'
}

# sh_other_shell FILE: its first line is a shebang for a shell ShellCheck can't read (dash is sh enough)
sh_other_shell() {
  head -1 "$1" 2>/dev/null | grep -qE '^#!(/usr)?/bin/(env[[:space:]]+)?(zsh|fish|ksh|mksh|pdksh|csh|tcsh)([[:space:]]|$)'
}

sh_wants() {
  local b=${1##*/}
  case $b in
    *.sh | *.bash)
      ! sh_other_shell "$1"
      ;;
    *.*)
      return 1
      ;;
    *)
      sh_bash_shebang "$1"
      ;;
  esac
}

# sh_editorconfig: the repo declares its shell style in an .editorconfig at its root
sh_editorconfig() { [[ -f ${top:-$PWD}/.editorconfig ]]; }

sh_format() {
  sh_editorconfig || return 3
  command -v shfmt >/dev/null || return 3
  shfmt --filename "$1"
}

sh_check() {
  check_format "$@"
  sh_shellcheck "$@"
}

# sh_shellcheck FILE...: one pass over all of them; `-x` would follow source lines outside the change
sh_shellcheck() {
  local rc=0 path line code msg
  need shellcheck "the shell lint" || return 0
  bounded shellcheck -S warning -f gcc "$@" >"$(scratch sh.sc.out)" 2>"$(scratch sh.sc.err)" || rc=$?
  if ((rc == 124)); then
    note "shellcheck ran out of time"
    return 0
  fi
  if ((rc != 0 && rc != 1)); then
    note "shellcheck failed: $(head -1 "$(scratch sh.sc.err)")"
    return 0
  fi
  sed -n -E 's/^(.*):([0-9]+):[0-9]+: (warning|error): (.*) \[SC([0-9]+)\]$/\1\t\2\t\5\t\4/p' "$(scratch sh.sc.out)" |
    while IFS=$'\t' read -r path line code msg; do
      finding warn "$(from_repo "$path")" "$line" "shellcheck-SC$code" "$msg"
    done
}
