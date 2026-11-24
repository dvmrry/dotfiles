#!/usr/bin/env bash
# Tests for guardrail.sh: bash claude/test-guardrail.sh
# Each case is a tool call and the answer the guardrail must give: deny, ask, or - (no opinion).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
g=${GUARDRAIL:-$here/guardrail.sh} # or the installed one: GUARDRAIL=$(command -v claude-guardrail)
export HOME=/Users/dm
cwd=/Users/dm/src/gh/dvmrry/medina
fails=0

answer() { # answer TOOL INPUT-JSON: the decision, or - for none
  local out
  out=$(jq -cn --arg t "$1" --arg c "$cwd" --argjson i "$2" '{tool_name: $t, cwd: $c, tool_input: $i}' | bash "$g")
  if [[ -z $out ]]; then echo -; else jq -r '.hookSpecificOutput.permissionDecision' <<<"$out"; fi
}
check() { # check WANT TOOL INPUT-JSON
  local got
  got=$(answer "$2" "$3")
  if [[ $got == "$1" ]]; then echo "ok   $1  $2 $3"; else
    echo "FAIL want $1 got $got  $2 $3"
    fails=$((fails + 1))
  fi
}
bash_() { check "$1" Bash "$(jq -cn --arg c "$2" '{command: $c}')"; }
file_() { check "$1" "$2" "$(jq -cn --arg p "$3" '{file_path: $p}')"; }

# Claude Code's own settings: never
file_ deny Edit "$HOME/.claude/settings.json"
file_ deny Write "/Users/dm/src/x/.claude/settings.local.json"
file_ deny Write "/Library/Application Support/ClaudeCode/managed-settings.json"
bash_ deny "jq '.hooks = {}' ~/.claude/settings.json > /tmp/s && mv /tmp/s ~/.claude/settings.json"
bash_ deny "sed -i 's/ask/allow/' .claude/settings.local.json"
bash_ deny "sudo rm '/Library/Application Support/ClaudeCode/managed-settings.json'"
file_ - Read "$HOME/.claude/settings.json" # reading them is fine
bash_ - "jq .hooks ~/.claude/settings.json"

# the guardrail's own source
file_ ask Edit "/Users/dm/.config/nix-darwin/claude/guardrail.sh"
file_ ask Write "/Users/dm/.config/nix-darwin/modules/darwin/claude-guardrail.nix"

# force pushes
bash_ ask "git push --force origin main"
bash_ ask "git push -f"
bash_ ask "git push --force-with-lease origin feature"
bash_ ask "git push origin +main"
bash_ ask "cd repo && git push -uf origin x"
bash_ - "git push origin main"
bash_ - "git push -u origin feature --follow-tags"
bash_ - "git push"

# credentials
file_ ask Read "$HOME/.ssh/id_ed25519"
file_ ask Read "$HOME/.config/medina/token"
file_ ask Read "/Users/dm/src/app/.env"
file_ ask Read "/Users/dm/src/app/.env.production"
file_ - Read "$HOME/.ssh/id_ed25519.pub"
file_ - Read "$HOME/.ssh/config"
file_ - Read "/Users/dm/src/app/.envrc"
bash_ ask "cat ~/.ssh/id_ed25519"
bash_ ask "base64 < ~/.config/medina/token"
bash_ ask "grep KEY .env"
bash_ ask "security find-generic-password -s foo -w"
bash_ ask "op read op://vault/item/password"
bash_ ask "sops -d secrets/cm02.yaml"
bash_ - "ls ~/.ssh"
bash_ - "ssh im01 uptime"
bash_ - "direnv allow .envrc"
bash_ - "sops secrets/cm02.yaml" # opens the editor, nothing printed

# destructive cluster and machine commands
bash_ ask "kubectl delete pod foo -n ai"
bash_ ask "kubectl -n ai scale deploy x --replicas=0"
bash_ ask "talosctl -n 172.17.0.11 reboot"
bash_ ask "talosctl apply-config -n 1.2.3.4 -f c.yaml"
bash_ ask "flux suspend kustomization apps"
bash_ ask "tofu apply -auto-approve"
bash_ ask "terraform state rm aws_instance.x"
bash_ ask "helm uninstall searxng -n ai"
bash_ ask "zfs destroy tank/data"
bash_ ask "sudo darwin-rebuild switch --flake ~/.config/nix-darwin"
bash_ ask "drs"
bash_ ask "ssh im01 sudo reboot"
bash_ ask "diskutil eraseDisk APFS X disk4"
bash_ ask "dd if=img of=/dev/disk4 bs=4m"
bash_ ask "sudo ls /var/root"
bash_ - "kubectl get pods -A"
bash_ - "kubectl -n ai logs deploy/searxng"
bash_ - "talosctl -n 172.17.0.11 get members"
bash_ - "flux get kustomizations"
bash_ - "tofu plan"
bash_ - "helm list -A"
bash_ - "nix build .#darwinConfigurations.cm02.system"
bash_ - "echo reboot later" # a word in an argument isn't the command

# merges, deploys, publishes
bash_ ask "gh pr merge 59 --squash"
bash_ ask "gh release create v1.0"
bash_ ask "npx wrangler deploy"
bash_ ask "npm publish"
bash_ ask "docker push ghcr.io/x/y"
bash_ - "gh pr view 59"
bash_ - "gh pr create --fill"
bash_ - "git merge --ff-only origin/main"

# recursive deletes
bash_ ask "rm -rf ~/src"
bash_ ask "rm -rf /"
bash_ ask "rm -r ../other-repo"
bash_ ask "rm -rf \$HOME/Library/Caches"
bash_ ask "cd /tmp && rm -rf /Users/dm/src/gh/dvmrry/other"
bash_ - "rm -rf node_modules"
bash_ - "rm -rf ./build dist"
bash_ - "rm -rf /Users/dm/src/gh/dvmrry/medina/dist"
bash_ - "rm -rf /tmp/scratch"
bash_ - "rm -rf /private/tmp/claude-501/x"
bash_ - "rm ~/notes.txt" # not recursive

# other tools and unreadable input
check - Grep '{"pattern": "x"}'
got=$(printf 'not json' | bash "$g" | jq -r '.hookSpecificOutput.permissionDecision')
if [[ $got == ask ]]; then echo "ok   ask  unreadable input"; else
  echo "FAIL want ask got $got  unreadable input"
  fails=$((fails + 1))
fi

echo
((fails)) && {
  echo "$fails failed"
  exit 1
}
echo "all passed"
