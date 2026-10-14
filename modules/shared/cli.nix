# CLI tools every host gets, Mac or NixOS: what you reach for at a shell on
# any box, including a jumpbox debugging the LAN. Imported by
# modules/darwin/base.nix and modules/nixos/base.nix; environment.systemPackages
# means the same thing in nix-darwin and NixOS. Platform-only tools stay in
# those two files.
{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    # Core tools
    age
    bc
    curl
    fd
    file
    fzf
    git
    jq
    less
    ncdu
    pv
    ripgrep
    rsync
    sops
    sqlite
    tmux
    tree
    unzip
    vim
    wget
    yq
    zip
    zstd

    # Processes
    btop
    htop

    # Network. mtr and tcpdump need root on the Macs too: run them with sudo.
    dnsutils # dig
    iperf3
    mtr
    tcpdump
  ];
}
