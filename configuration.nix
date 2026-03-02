{ pkgs, ... }: {

  # Packages installed system-wide
  environment.systemPackages = with pkgs; [
    # Core tools
    age
    curl
    fd
    ffmpeg
    fzf
    gh
    gnumake
    gnupg
    httpie
    jq
    nmap
    ripgrep
    shellcheck
    sops
    starship
    tree
    watch
    wget
    yamllint
    yq

    # Editors
    neovim
    vim

    # Languages & runtimes
    nodejs
    python3
    rustup

    # Dev tools
    go-task
    pre-commit

    # Git
    git
    git-lfs

    # Kubernetes
    kubecolor
    kubectl
    kubectx
    kubernetes-helm

    # Infrastructure
    fluxcd
    opentofu
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
    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "zap";
    };
    taps = [
      "LizardByte/homebrew"
    ];
    brews = [
      "LizardByte/homebrew/sunshine-beta"
    ];
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
      wvous-bl-corner = 1; # disable hot corners
      wvous-br-corner = 1;
      wvous-tl-corner = 1;
      wvous-tr-corner = 1;
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
    loginwindow = {
      GuestEnabled = false;
      DisableConsoleAccess = true;
    };
    menuExtraClock = {
      Show24Hour = true;
      ShowSeconds = false;
    };
    screencapture = {
      location = "~/Pictures/Screenshots";
      type = "png";
      disable-shadow = true;
    };
    screensaver = {
      askForPassword = true;
      askForPasswordDelay = 0;
    };
    WindowManager = {
      GloballyEnabled = false;
      EnableStandardClickToShowDesktop = false;
    };
    NSGlobalDomain = {
      AppleShowAllExtensions = true;
      AppleInterfaceStyle = "Dark";
      AppleKeyboardUIMode = 3; # full keyboard access
      "com.apple.swipescrolldirection" = true; # natural scrolling
      "com.apple.sound.beep.volume" = 0.0;
      "com.apple.sound.beep.feedback" = 0;
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
      ApplePressAndHoldEnabled = false;
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;
      NSAutomaticPeriodSubstitutionEnabled = false;
      NSAutomaticQuoteSubstitutionEnabled = false;
      NSAutomaticSpellingCorrectionEnabled = false;
      NSNavPanelExpandedStateForSaveMode = true;
      NSNavPanelExpandedStateForSaveMode2 = true;
    };
    CustomUserPreferences = {
      "com.apple.desktopservices" = {
        DSDontWriteNetworkStores = true;
        DSDontWriteUSBStores = true;
      };
      "com.apple.AdLib" = {
        allowApplePersonalizedAdvertising = false;
      };
      "com.apple.SoftwareUpdate" = {
        AutomaticCheckEnabled = true;
        ScheduleFrequency = 1;
        AutomaticDownload = 1;
        CriticalUpdateInstall = 1;
      };
      "com.apple.ImageCapture" = {
        disableHotPlug = true;
      };
    };
    SoftwareUpdate.AutomaticallyInstallMacOSUpdates = false;
  };

  # Reload preferences immediately after activation
  system.activationScripts.postActivation.text = ''
    sudo -u dm /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';

  # Shells
  environment.shells = with pkgs; [ bash zsh fish ];
  programs.fish.enable = true;
  users.users.dm = {
    name = "dm";
    home = "/Users/dm";
    shell = pkgs.fish;
  };

  # Primary user for per-user system defaults
  system.primaryUser = "dm";

  # Hostname
  networking.hostName = "cm01";

  # Nix - managed by Determinate installer
  determinateNix = {
    enable = true;
    determinateNixd.garbageCollector.strategy = "automatic";
    customSettings = {
      keep-outputs = true;
      keep-derivations = true;
      warn-dirty = false;
      extra-substituters = [ "https://nix-community.cachix.org" ];
      extra-trusted-public-keys = [ "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=" ];
    };
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Used for backwards compatibility
  system.stateVersion = 6;

  # The platform the configuration will be used on
  nixpkgs.hostPlatform = "aarch64-darwin";
}
