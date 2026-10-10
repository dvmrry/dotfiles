# GMKtec EVO-X2: Ryzen AI Max+ 395 (Strix Halo), Radeon 8060S (gfx1151),
# 128 GB unified memory. Headless inference box. BIOS: UMA frame buffer 1G,
# Secure Boot off, IOMMU off.
{ pkgs, inputs, ... }: {
  imports = [
    inputs.disko.nixosModules.disko
    ./disk.nix
    ./hardware-configuration.nix
  ];

  # Boot: newest kernel for Strix Halo amdgpu/NPU/MT7925 support
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [
    # +1-16% prefill; also disables the NPU (amdxdna needs the IOMMU)
    "amd_iommu=off"
    # Cap on system RAM the iGPU may map as GTT: 124 GiB in 4 KiB pages.
    # Don't raise ttm.page_pool_size to match: a pool near RAM size deadlocks
    # in drm_suballoc_new (unkillable, reboot only).
    "ttm.pages_limit=32505856"
    # Halogen: prevents silent GPU hangs (halogen-flash-server issue #83)
    "amdgpu.noretry=0"
  ];

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode = true;
  hardware.graphics.enable = true; # Mesa / RADV Vulkan

  zramSwap.enable = true;

  # Networking: DHCP on wired (preferred) and Wi-Fi, mDNS so im01.local resolves
  networking.hostName = "im01";
  networking.useNetworkd = true;
  systemd.network.networks."10-wired" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "yes";
  };
  # Wi-Fi (MT7925) via iwd. Credentials are entered once on the box and kept
  # by iwd in /var/lib/iwd, never in this repo:
  #   sudo iwctl station wlp195s0 connect <SSID>
  # Off until a prod SSID exists on the wired VLAN: on 172.19.0.0/24 Wi-Fi adds
  # an on-link route to the Macs' subnet, so replies to them leave via wlan0
  # and the gateway drops the half-seen flow. Credentials in /var/lib/iwd stay.
  networking.wireless.iwd = {
    enable = false;
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
  # 8731: Halogen API (no auth - LAN only)
  networking.firewall.allowedTCPPorts = [ 22 8731 ];

  time.timeZone = "America/New_York";

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
  # dm has no password (key-only), so sudo can't prompt for one
  security.sudo.wheelNeedsPassword = false;

  programs.fish.enable = true;

  environment.systemPackages = with pkgs; [
    amdgpu_top
    btop
    curl
    ghostty.terminfo # SSH sessions from Ghostty (TERM=xterm-ghostty)
    git
    jq
    pciutils
    tmux
    usbutils
    vim
  ];

  # Inference: Halogen serving Qwen 3.8 Flash Next (OpenAI, Responses and
  # Anthropic Messages APIs on :8731). Proprietary EULA, binary-only, no
  # telemetry. First start downloads ~111 GB into /var/lib/halogen/models.
  virtualisation.podman.enable = true;
  virtualisation.oci-containers = {
    backend = "podman";
    containers.halogen = {
      image = "ghcr.io/peonist-ai/halogen-flash-server:0.17.4";
      ports = [ "8731:8731" ];
      volumes = [ "/var/lib/halogen/models:/models" ];
      # No HALOGEN_TEMPERATURE on purpose: requests without a temperature
      # decode greedy, which scored better on real worker tasks than Qwen's
      # recommended sampling (temp 1.0 / top_p 0.95 / top_k 20).
      environment = {
        HALOGEN_DOWNLOAD = "peonist-ai/halogen-qwen3.8-flash-next";
      };
      extraOptions = [
        "--device=/dev/kfd"
        "--device=/dev/dri"
        "--ipc=host"
        "--ulimit=memlock=-1:-1"
      ];
    };
  };
  systemd.tmpfiles.rules = [ "d /var/lib/halogen/models 0755 root root -" ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "@wheel" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "26.05";
}
