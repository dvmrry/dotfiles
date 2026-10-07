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
    "amd_iommu=off"
    # Let the iGPU map up to ~115 GiB of system RAM as GTT (4 KiB pages)
    "ttm.pages_limit=30146560"
    "ttm.page_pool_size=30146560"
  ];

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode = true;
  hardware.graphics.enable = true; # Mesa / RADV Vulkan

  zramSwap.enable = true;

  # Networking: DHCP on wired, mDNS so im01.local resolves
  networking.hostName = "im01";
  networking.useNetworkd = true;
  systemd.network.networks."10-wired" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "yes";
  };
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };
  networking.firewall.allowedTCPPorts = [ 22 ];

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
