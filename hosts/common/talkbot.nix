# Unprivileged shell account for the voice bot on gm01 (talk.mrry.io), so it can
# answer questions about the boxes by running commands itself. No sudo, no
# wheel/podman/video groups: it sees what any local user sees (/proc, lspci,
# its own home) and can't touch the services. The key was generated on gm01
# (/var/lib/voice-spike/talk/talkbot_ed25519, root-only) and is accepted only
# from gm01's wired address, with no forwarding, agent or X11 (`restrict`).
_: {
  users.users.talkbot = {
    isNormalUser = true;
    description = "Voice bot shell (unprivileged)";
    home = "/var/lib/talkbot";
    createHome = true;
    openssh.authorizedKeys.keys = [
      ''from="172.19.0.168",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPmJAI2+gvCRGerwBxGp/58OH1nXNsNjJrntkGn31sTi talkbot@gm01-voice''
    ];
  };
  services.openssh.settings.AllowUsers = [ "talkbot" ];
}
