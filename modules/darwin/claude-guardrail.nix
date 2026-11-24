# The baseline guardrail for every Claude Code session on this Mac, whoever started it (claude/guardrail.sh says
# what it asks about and what it refuses). It goes in through Claude Code's managed settings, a root-owned file a
# session can't change, so changing the guardrail takes a PR and `drs`.
#
# This is not ~/.claude (which stays Claude Code's own, see CLAUDE.md): Claude Code never writes managed settings.
# Its hooks run alongside the user's own (agent-check, medina's), and when hooks disagree the strictest answer wins,
# so medina's stricter hook for the tasks it sends sits on top of this one without either knowing about the other.
# allowManagedHooksOnly stays off: it would switch those other hooks off, and nothing here needs it.
{ pkgs, ... }:
let
  guardrail = pkgs.writeShellApplication {
    name = "claude-guardrail";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gnused
      jq
    ];
    text = builtins.readFile ../../claude/guardrail.sh;
  };
  managed = pkgs.writeText "claude-managed-settings.json" (
    builtins.toJSON {
      hooks.PreToolUse = [
        {
          matcher = "Bash|Read|Edit|Write|MultiEdit|NotebookEdit";
          hooks = [
            {
              type = "command";
              command = "${guardrail}/bin/claude-guardrail";
              timeout = 10;
            }
          ];
        }
      ];
    }
  );
in
{
  # on PATH too, to test the installed copy: GUARDRAIL=$(command -v claude-guardrail) bash claude/test-guardrail.sh
  environment.systemPackages = [ guardrail ];

  system.activationScripts.postActivation.text = ''
    echo "installing Claude Code's managed settings (the baseline guardrail)"
    /usr/bin/install -d -m 755 -o root -g wheel "/Library/Application Support/ClaudeCode"
    /usr/bin/install -m 644 -o root -g wheel ${managed} "/Library/Application Support/ClaudeCode/managed-settings.json"
  '';
}
