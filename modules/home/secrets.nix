# sops/age secrets from secrets/*.yaml. The age key is restored once from
# 1Password (see README). The 1Password service account token is only loaded
# in SSH sessions, where the desktop app's CLI integration isn't available.
{ pkgs, ... }: {
  home.packages = [ pkgs.sops ];

  home.sessionVariables.SOPS_AGE_KEY_FILE = "$HOME/.config/sops/age/keys.txt";

  programs.fish.interactiveShellInit = ''
    set -gx SOPS_AGE_KEY_FILE "$HOME/.config/sops/age/keys.txt"

    # 1Password service account (sops-encrypted), SSH sessions only
    if set -q SSH_CONNECTION; and not set -q OP_SERVICE_ACCOUNT_TOKEN; and test -f "$SOPS_AGE_KEY_FILE"
      set -gx OP_SERVICE_ACCOUNT_TOKEN (sops --decrypt --extract '["op_service_account_token"]' ~/.config/nix-darwin/secrets/op.yaml 2>/dev/null)
    end
  '';
}
