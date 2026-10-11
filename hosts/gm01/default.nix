# ASUS ROG Strix B650E-I, Ryzen 7 7800X3D, 64 GB DDR5-6000, RTX 4070 Ti
# Super 16 GB. Headless gaming box streamed with Punktfunk (SteamOS-style, no
# desktop); local LLMs later. BIOS: Secure Boot off, iGPU off.
{ config, pkgs, inputs, ... }: {
  imports = [
    inputs.disko.nixosModules.disko
    ./disk.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Keep the CPU's iGPU (Raphael) idle so games and NVENC stay on the 4070 Ti
  # Super, even with the iGPU on Auto in the BIOS.
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
  #   sudo iwctl station wlan0 connect <SSID>
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
    # No one is logged in at the seat, so don't hold Bluetooth audio back
    # until someone is (sound cards: dm is in `audio`, below)
    wireplumber.extraConfig."10-no-seat"."wireplumber.profiles".main = {
      "monitor.bluez.seat-monitoring" = "disabled";
    };
  };

  # No desktop and no login: Punktfunk starts a headless gamescope running
  # Steam Big Picture for each client (see services.punktfunk below). dm's
  # user services (Punktfunk, PipeWire) run from boot, like im01's Halogen.
  users.users.dm.linger = true;
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

  # Streaming: Punktfunk host. Each client gets its own headless gamescope
  # ("bare spawn") at the client's resolution and refresh rate, with HDR via
  # punktfunk's patched gamescope. Pair from the web console on :47992.
  # Moonlight (GameStream) is off; enable with host.gamestream = true.
  services.punktfunk.host = {
    enable = true;
    users = [ "dm" ];
    openFirewall = true;
    autoStart = true; # with linger: up at boot, no login needed
    settings = {
      PUNKTFUNK_COMPOSITOR = "gamescope"; # no session to detect
      PUNKTFUNK_GAMESCOPE_APP = "steam -gamepadui"; # Big Picture in each stream
    };
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
    # audio: sound cards are otherwise granted only to a seat login, and
    # gm01 has none
    extraGroups = [ "wheel" "video" "render" "audio" ];
    shell = pkgs.fish;
    # 1Password id_ed25519
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8zyMqlC1LHHWWk0v/wdfaVGYBoZSvD64xaAQZ5dOYh"
    ];
  };
  # dm has no password (key-only), so sudo can't prompt for one
  security.sudo.wheelNeedsPassword = false;

  programs.fish.enable = true;

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
