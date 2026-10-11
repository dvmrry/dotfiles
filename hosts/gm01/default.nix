# Desktop: ASUS ROG Strix B650E-I, Ryzen 7 7800X3D, 64 GB DDR5-6000,
# RTX 4070 Ti Super 16 GB. Mostly headless gaming box streamed with Punktfunk,
# sometimes used at a DP monitor; local LLMs later. BIOS: Secure Boot off.
{ config, pkgs, inputs, ... }: {
  imports = [
    inputs.disko.nixosModules.disko
    ./disk.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Keep the CPU's iGPU (Raphael) idle so the desktop, games and NVENC all
  # stay on the 4070 Ti Super; plug monitors into the graphics card.
  boot.blacklistedKernelModules = [ "amdgpu" ];

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode = true;

  # NVIDIA: open kernel module (Ada), proprietary userspace
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open = true;
    modesetting.enable = true;
  };
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # Steam / Proton
  };

  zramSwap.enable = true;

  # Networking: DHCP on wired (preferred) and Wi-Fi. Both sit on the Macs'
  # subnet, so a reply to traffic that came in on one can leave via the other;
  # strict reverse-path filtering would drop those.
  networking.hostName = "gm01";
  networking.useNetworkd = true;
  networking.firewall.checkReversePath = "loose";
  systemd.network.networks."10-wired" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "yes";
  };
  # Wi-Fi (MT7922) via iwd. Credentials are entered once on the box and kept
  # by iwd in /var/lib/iwd, never in this repo:
  #   sudo iwctl station wlp9s0 connect <SSID>
  networking.wireless.iwd = {
    enable = true;
    settings.General.EnableNetworkConfiguration = false; # networkd does DHCP
  };
  systemd.network.networks."20-wireless" = {
    matchConfig.Name = "wl*";
    networkConfig.DHCP = "yes";
    dhcpV4Config.RouteMetric = 2048; # wired (1024) wins when plugged in
    ipv6AcceptRAConfig.RouteMetric = 2048;
  };
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  time.timeZone = "America/New_York";

  hardware.bluetooth.enable = true; # controllers when playing locally

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Desktop: Plasma 6 (Wayland), logged in at boot so a streamed session
  # always has a desktop to attach to
  services.desktopManager.plasma6.enable = true;
  services.displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;
    };
    autoLogin = {
      enable = true;
      user = "dm";
    };
    defaultSession = "plasma";
  };
  # No idle lock: a locked screen would greet every stream (system default;
  # Plasma's own settings still override it per user)
  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=false
    LockOnResume=false
  '';
  # Never sleep: a suspended box can't be streamed to
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # Gaming
  programs.steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ]; # try Valve's Proton first
    protontricks.enable = true;
  };
  programs.gamemode.enable = true;
  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  # Streaming: Punktfunk host, one virtual display per client at its own
  # resolution and refresh rate. Pair from the web console on :47992.
  # Moonlight (GameStream) is off; enable with host.gamestream = true.
  services.punktfunk.host = {
    enable = true;
    users = [ "dm" ];
    openFirewall = true;
    autoStart = true;
    desktopSession = true; # restart with Plasma, or capture breaks silently
  };

  # SSH: key-only, same hardening as the Macs
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "dm" ];
      X11Forwarding = false;
    };
  };

  # Pinned SSH host keys (from https://api.github.com/meta)
  programs.ssh.knownHosts.github = {
    hostNames = [ "github.com" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
  };

  users.users.dm = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "render" ];
    shell = pkgs.fish;
    # 1Password id_ed25519
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8zyMqlC1LHHWWk0v/wdfaVGYBoZSvD64xaAQZ5dOYh"
    ];
  };
  # dm logs in by key (SSH) or autologin (desktop); sudo can't prompt for a
  # password it doesn't have. Set one with `passwd` for local use if wanted.
  security.sudo.wheelNeedsPassword = false;

  programs.fish.enable = true;
  programs.firefox.enable = true;

  environment.systemPackages = with pkgs; [
    btop
    curl
    ghostty.terminfo # SSH sessions from Ghostty (TERM=xterm-ghostty)
    git
    jq
    mangohud # per game: `mangohud %command%`
    nvtopPackages.nvidia
    pciutils
    tmux
    usbutils
    vim
  ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "@wheel" ];
    # Punktfunk's binary cache; hits only while gm01's nixpkgs follows
    # punktfunk's (see flake.nix)
    extra-substituters = [ "https://nix.unom.io" ];
    extra-trusted-public-keys = [ "punktfunk-cache-1:yhOJmHxzg6tzXpxSFzlYn6Pc6r0jHprsWqt8MZC654o=" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nixpkgs.config.allowUnfree = true; # NVIDIA, Steam

  system.stateVersion = "26.11";
}
