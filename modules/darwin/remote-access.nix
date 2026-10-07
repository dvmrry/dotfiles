# Remote Login (SSH) with key-only auth, and power settings so the machine
# stays reachable. Displays still sleep; the computer doesn't.
{ ... }: {
  services.openssh = {
    enable = true;
    extraConfig = ''
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitRootLogin no
      AllowUsers dm
      KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
      Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
      MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
      ClientAliveInterval 60
      ClientAliveCountMax 5
      MaxAuthTries 3
      MaxSessions 10
      LoginGraceTime 30
      X11Forwarding no
      PermitEmptyPasswords no
      LogLevel VERBOSE
    '';
  };

  # 1Password id_ed25519
  users.users.dm.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8zyMqlC1LHHWWk0v/wdfaVGYBoZSvD64xaAQZ5dOYh"
  ];

  power.sleep.computer = "never";
  power.sleep.display = 15;
  power.restartAfterPowerFailure = true;
  power.restartAfterFreeze = true;
  networking.wakeOnLan.enable = true;
}
