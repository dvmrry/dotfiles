#!/usr/bin/env bash
# claude-guardrail: the baseline guardrail, a Claude Code PreToolUse hook for every session on this Mac, whoever
# started it (Dave, medina, or a session working on medina itself). Installed through Claude Code's managed settings
# (modules/darwin/claude-guardrail.nix), which only root can change: a session can't edit or switch it off; changing
# it takes a PR and `drs`.
#
# It's the bottom layer. Other hooks (medina's own, for the tasks it sends) add stricter answers on top: when hooks
# disagree, Claude Code takes the strictest (deny, then ask, then allow), so the layers never need to know about each
# other or who started an action.
#
# It answers with one of:
#   deny   never, whatever the session's permissions: changing Claude Code's own settings
#   ask    the session's permission dialog, even in auto mode: force pushes, recursive deletes outside the project,
#          reading credentials, destructive cluster or machine commands, merges, deploys and publishes, sudo,
#          and edits to this guardrail's own source
#   (none) no opinion: the session's own permissions decide
# A call it can't read gets `ask`, never silence.
#
# Rules match the command text, so they catch mistakes, not a determined adversary (a script that does the same
# thing isn't seen). Tests: bash claude/test-guardrail.sh
set -uo pipefail

decide() { # decide DECISION REASON: print the hook's answer and stop
  jq -cn --arg d "$1" --arg r "guardrail: $2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
  exit 0
}

input=$(cat) || decide ask "couldn't read this call, so it asks"
tool=$(jq -er '.tool_name' <<<"$input" 2>/dev/null) || decide ask "couldn't read this call, so it asks"
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
home=${HOME:-/Users/dm}

# --- Paths ---------------------------------------------------------------------------------------------------------
# Claude Code's settings: the session's own permissions and hooks live here
settings_re='(^|/)\.claude/settings(\.local)?\.json$|^/Library/Application Support/ClaudeCode(/|$)'
# this guardrail's source: an edit lands only after a PR and `drs`, but Dave should see it happen
self_re='/claude/(guardrail\.sh|test-guardrail\.sh)$|/modules/darwin/claude-guardrail\.nix$'
# credentials: private keys, tokens, env files (not public keys, known_hosts or ssh config)
cred_re='/\.ssh/(id_[a-z0-9]+|[^/]*\.(pem|key))$|/\.config/medina/(token|env|lan/(key\.pem|password))$|/\.aws/credentials$|/\.netrc$|/\.git-credentials$|/\.env(\.[a-z]+)?$|/secrets?/[^/]*\.(pem|key)$'

abs() { # a path as an absolute one, ~ and relative paths resolved (not symlinks)
  local p=$1
  # shellcheck disable=SC2088 # a literal ~ from the tool's input, expanded here
  case $p in
    "~") p=$home ;;
    "~/"*) p=$home/${p#"~/"} ;;
    /*) ;;
    *) p=${cwd:-$PWD}/$p ;;
  esac
  printf '%s' "$p"
}

case $tool in
  Read | Edit | Write | MultiEdit | NotebookEdit)
    path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input" 2>/dev/null) ||
      decide ask "couldn't read this call, so it asks"
    [[ -z $path ]] && exit 0
    path=$(abs "$path")
    if [[ $tool != Read ]]; then
      [[ $path =~ $settings_re ]] && decide deny "a session doesn't change Claude Code's own settings ($path); ask Dave to do it himself"
      [[ $path =~ $self_re ]] && decide ask "this edits the guardrail itself"
    fi
    [[ $path =~ $cred_re ]] && decide ask "this reads or writes a credential file ($path)"
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

cmd=$(jq -er '.tool_input.command' <<<"$input" 2>/dev/null) || decide ask "couldn't read this command, so it asks"

# --- Commands, anywhere in the text ---------------------------------------------------------------------------------
# GNU grep, not bash's =~: macOS's own regex library doesn't know \b or \s
# (`command`: Claude Code's Bash tool shadows grep with a function of its own, which a child shell can inherit)
m() { command grep -qE -- "$1" <<<"$cmd"; }
seg='[^;&|]*' # the rest of one command, up to the next ; & or |

# Claude Code's settings, written to: deny
writes='(>|\btee\b|\bsed\b'"$seg"'\s-i|\b(mv|cp|rm|ln|install|chmod|chown|truncate|plutil|sponge)\b)'
if m '\.claude/settings(\.local)?\.json|Application Support/ClaudeCode' && m "$writes"; then
  decide deny "a session doesn't change Claude Code's own settings; ask Dave to do it himself"
fi

ask_if() { # ask_if REGEX REASON
  m "$1" && decide ask "$2"
  return 0
}

ask_if '\bgit\b'"$seg"'\bpush\b'"$seg"'(\s--force(-with-lease|-if-includes)?\b|\s-[a-zA-Z]*f[a-zA-Z]*\b|\s\+[^ ]+)' \
  "a force push rewrites a remote's history"

# credentials: reading a credential file, or asking a store for a secret
readers='\b(cat|less|more|head|tail|bat|base64|xxd|od|strings|cp|scp|rsync|grep|rg|awk|sed|jq|op|curl)\b'
credpath='\.ssh/(id_[a-z0-9]+|[^ /]*\.(pem|key))\b|\.config/medina/(token|env|lan/(key\.pem|password))\b|\.aws/credentials\b|\.netrc\b|\.git-credentials\b|(^|[ /"'\''])\.env(\.[a-z]+)?($|[ "'\''])'
if m "$credpath" && { m "$readers" || m '<\s*[^ ]*(\.ssh|\.config/medina|\.env)'; }; then
  decide ask "this reads a credential file"
fi
ask_if '\bsecurity\s+(find|dump)-(generic|internet)-password\b|\bsecurity\s+dump-keychain\b|\bop\s+(read|inject)\b|\bop\s+item\s+get\b|\bsops\b'"$seg"'(\s-d\b|\s--decrypt\b|\sdecrypt\b)' \
  "this takes a secret out of a password store"

# destructive cluster and machine commands
ask_if '\bkubectl\b'"$seg"'\b(delete|drain|cordon|taint)\b|\bkubectl\b'"$seg"'\bscale\b'"$seg"'--replicas[= ]0\b' \
  "this removes or takes down something on the cluster"
ask_if '\btalosctl\b'"$seg"'\b(reset|reboot|shutdown|upgrade|upgrade-k8s|apply-config|apply|rollback|wipe)\b' \
  "this changes or restarts a Talos machine"
ask_if '\bflux\b'"$seg"'\b(delete|uninstall|suspend)\b' "this stops or removes Flux's reconciliation"
ask_if '\b(tofu|terraform)\b'"$seg"'\b(apply|destroy|import)\b|\b(tofu|terraform)\b'"$seg"'\bstate\s+(rm|mv|push)\b' \
  "this changes real infrastructure"
ask_if '\bhelm\b'"$seg"'\b(uninstall|delete|rollback)\b' "this removes or rolls back a release"
ask_if '\b(zfs|zpool)\s+(destroy|rollback)\b|\b(qm|pct)\s+(destroy|stop|shutdown|reboot)\b' \
  "this destroys or stops storage or a VM"
ask_if '\b(darwin-rebuild|nixos-rebuild|nixos-rebuild-ng)\b'"$seg"'\b(switch|boot|test|activate)\b|\bnixos-anywhere\b|(^|[;&|(]\s*)drs\b' \
  "this rebuilds a machine's system"
ask_if '(^|[;&|(]\s*|\bsudo\s+|\bssh\s+[^;&|]*\s)(shutdown|reboot|halt|poweroff)\b' "this shuts down or restarts a machine"
ask_if '\bdiskutil\s+(erase[a-zA-Z]*|partitionDisk|zeroDisk|secureErase|apfs\s+delete[a-zA-Z]*)\b|\bdd\b'"$seg"'\bof=/dev/|\b(mkfs(\.[a-z0-9]+)?|wipefs)\b' \
  "this erases a disk"
ask_if '(^|[;&|(]\s*)sudo\b' "this runs as root"

# merges, deploys and publishes
ask_if '\bgh\s+pr\s+merge\b' "this merges a pull request"
ask_if '\bgh\s+release\s+create\b|\bgh\s+workflow\s+run\b|\bgh\s+repo\s+(delete|archive)\b' "this releases, runs a workflow or removes a repo"
ask_if '\b(wrangler|flyctl|fly|vercel|netlify)\b'"$seg"'\b(deploy|publish)\b|\b(npm|pnpm|yarn|bun)\s+publish\b|\bcargo\s+publish\b|\bdocker\s+push\b' \
  "this deploys or publishes"

# recursive deletes outside the project (or the temp folders): each rm in the command, target by target
IFS=$'\n' read -r -d '' -a parts < <(sed -E 's/(\|\||&&|[;&|])/\n/g' <<<"$cmd" && printf '\0')
for part in "${parts[@]}"; do
  read -r -a words <<<"$part"
  [[ ${words[0]:-} == sudo ]] && words=("${words[@]:1}")
  [[ ${words[0]:-} == rm ]] || continue
  recursive=0 targets=()
  for w in "${words[@]:1}"; do
    case $w in
      --recursive) recursive=1 ;;
      --*) ;;
      -*) [[ $w == *[rR]* ]] && recursive=1 ;;
      *) targets+=("$w") ;;
    esac
  done
  ((recursive)) || continue
  for t in "${targets[@]}"; do
    t=${t//\"/} t=${t//\'/}
    t=${t//\$HOME/$home} t=${t//\$\{HOME\}/$home}
    p=$(abs "$t")
    case $p in
      /tmp/* | /private/tmp/* | /private/var/folders/* | /var/folders/* | "${TMPDIR:-/nonexistent}"*) continue ;;
    esac
    if [[ $t == *..* || -z $cwd || $p != "$cwd"/* ]]; then
      decide ask "a recursive delete outside the project folder ($t)"
    fi
  done
done

exit 0
