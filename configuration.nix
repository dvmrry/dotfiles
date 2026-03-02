{ pkgs, ... }: {

  # Packages installed system-wide
  environment.systemPackages = with pkgs; [
    vim
    neovim
    git
    git-lfs
    curl
    wget
    ripgrep
    fd
    jq
    yq
    tree
    fzf
    watch
    nmap
    gnupg
    age
    sops
    ffmpeg
    httpie
    gh
    nodejs
    pre-commit
    starship

    # Kubernetes
    kubectl
    kubectx
    kubecolor
    kubernetes-helm

    # Infrastructure
    opentofu
    fluxcd
    talosctl

    # Nix helpers
    nh

    # 1Password CLI
    _1password-cli
  ];

  # Window manager - auto-tiling for headless screen capture use
  services.yabai = {
    enable = true;
    config = {
      layout = "bsp";
      window_placement = "second_child";
      window_shadow = "float";
      window_opacity = "off";
      top_padding = 16;
      bottom_padding = 16;
      left_padding = 16;
      right_padding = 16;
      window_gap = 16;
      auto_balance = "on";
      split_ratio = 0.50;
      mouse_modifier = "fn";
      mouse_action1 = "move";
      mouse_action2 = "resize";
      mouse_drop_action = "swap";
      mouse_follows_focus = "off";
    };
    extraConfig = ''
      # Float system windows
      yabai -m rule --add app="^System Settings$" manage=off
      yabai -m rule --add app="^System Information$" manage=off
      yabai -m rule --add app="^Activity Monitor$" manage=off
      yabai -m rule --add app="^App Store$" manage=off
      yabai -m rule --add app="^Finder$" title="(Co(py|nnect)|Move|Info|Pref)" manage=off
      yabai -m rule --add title="Software Update" manage=off
      yabai -m rule --add app="^1Password$" manage=off
    '';
  };

  # Enable Touch ID for sudo (reattach fixes Touch ID inside tmux)
  security.pam.services.sudo_local.touchIdAuth = true;
  security.pam.services.sudo_local.reattach = true;

  # Homebrew - for GUI apps (casks) that aren't in nixpkgs
  homebrew = {
    enable = true;
    onActivation.cleanup = "zap";
    casks = [
      "1password"
      "visual-studio-code"
      "font-fira-code-nerd-font"
    ];
  };

  # macOS system defaults
  system.defaults = {
    dock = {
      autohide = true;
      show-recents = false;
      mru-spaces = false;
    };
    finder = {
      AppleShowAllExtensions = true;
      AppleShowAllFiles = true;
      FXPreferredViewStyle = "clmv"; # column view
      FXDefaultSearchScope = "SCcf"; # search current folder
      FXEnableExtensionChangeWarning = false;
      ShowPathbar = true;
      ShowStatusBar = true;
      _FXSortFoldersFirst = true;
      QuitMenuItem = true;
    };
    NSGlobalDomain = {
      AppleShowAllExtensions = true;
      AppleInterfaceStyle = "Dark";
      "com.apple.swipescrolldirection" = true; # natural scrolling
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
      ApplePressAndHoldEnabled = false;
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;
      NSAutomaticQuoteSubstitutionEnabled = false;
      NSAutomaticSpellingCorrectionEnabled = false;
    };
  };

  # Declare the user so Home Manager can find the home directory
  users.users.dm = {
    name = "dm";
    home = "/Users/dm";
  };

  # Primary user for per-user system defaults
  system.primaryUser = "dm";

  # Hostname
  networking.hostName = "a2337";

  # Nix settings
  nix.enable = false; # Managed by Determinate installer
  # Note: nix.gc and nix.optimise require nix.enable = true
  # Run manually: nix-collect-garbage --delete-older-than 14d && nix store optimise

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Used for backwards compatibility
  system.stateVersion = 6;

  # The platform the configuration will be used on
  nixpkgs.hostPlatform = "aarch64-darwin";
}
