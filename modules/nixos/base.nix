# Shared system baseline for the NixOS boxes (im01, gm01): the CLI tools you
# reach for while debugging or benchmarking over SSH. The Linux counterpart of
# modules/darwin/base.nix. Host-specific tools (GPU monitors, engines) stay in
# each host's own list.
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
    python3
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

    # Processes, performance and debugging
    btop
    perf
    gdb
    htop
    hyperfine
    iotop
    lsof
    numactl
    psmisc # killall, pstree, fuser
    strace
    sysstat # iostat, mpstat, pidstat

    # Hardware
    dmidecode
    lm_sensors
    nvme-cli
    pciutils
    smartmontools
    usbutils

    # Network
    dnsutils # dig
    ethtool
    iperf3
    mtr
    netcat-openbsd
    tcpdump

    ghostty.terminfo # SSH sessions from Ghostty (TERM=xterm-ghostty)
  ];

  # bash as the login shell so `ssh host 'cmd'`, scp and remote scripts get
  # POSIX; interactive sessions exec fish instead. The parent check keeps
  # `nix develop` / `nix-shell` (bash started from fish) in bash.
  users.users.dm.shell = pkgs.bash;
  programs.fish.enable = true;
  programs.bash.interactiveShellInit = ''
    if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]; then
      shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
      exec ${pkgs.fish}/bin/fish $LOGIN_OPTION
    fi
  '';
}
