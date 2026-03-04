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
    mosh
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

    # System monitoring
    bandwhich
    btop
    macmon

    # Editors (neovim managed by nixCats in home.nix)

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
      mouse_modifier = "alt";
      mouse_action1 = "move";
      mouse_action2 = "resize";
      mouse_drop_action = "swap";
      focus_follows_mouse = "autofocus";
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
      yabai -m rule --add app="^Calculator$" manage=off
      yabai -m rule --add app="^Messages$" manage=off
      yabai -m rule --add app="^FaceTime$" manage=off
      yabai -m rule --add app="^Preview$" manage=off
    '';
  };

  # Hotkey daemon
  services.skhd = {
    enable = true;
    skhdConfig = ''
      # Toggle float on focused window
      alt - f : yabai -m window --toggle float; yabai -m window --grid 4:4:1:1:2:2

      # Balance all windows
      alt - b : yabai -m space --balance

      # Toggle layout (bsp / stack)
      alt - s : yabai -m space --layout "$(yabai -m query --spaces --space | jq -r 'if .type == "bsp" then "stack" else "bsp" end')"

      # Cycle focus
      alt - j : yabai -m window --focus next || yabai -m window --focus first
      alt - k : yabai -m window --focus prev || yabai -m window --focus last
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
      "font-fira-code-nerd-font"
      "ghostty"
      "vscodium"
    ];
  };

  # macOS system defaults
  system.defaults = {
    CustomUserPreferences."com.apple.WindowManager".HideDesktop = true;
    NSGlobalDomain."_HIHideMenuBar" = true;
    dock = {
      autohide = true;
      autohide-delay = 0.0;
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

  # Headless power management - never sleep
  power.sleep.computer = "never";
  power.sleep.display = "never";
  power.sleep.harddisk = "never";
  power.restartAfterFreeze = true;

  # SSH hardening
  environment.etc."ssh/sshd_config.d/hardening.conf".text = ''
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

  # Nightly nix store optimisation
  launchd.daemons.nix-store-optimise = {
    serviceConfig = {
      Label = "org.nixos.nix-store-optimise";
      ProgramArguments = [ "/bin/sh" "-c" "/run/current-system/sw/bin/nix store optimise" ];
      StartCalendarInterval = [{ Hour = 3; Minute = 30; }];
      StandardOutPath = "/var/log/nix-store-optimise.log";
      StandardErrorPath = "/var/log/nix-store-optimise.log";
    };
  };

  # Post-activation: reload preferences + headless pmset hardening
  system.activationScripts.postActivation.text = ''
    sudo -u dm /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

    # Headless pmset hardening
    pmset -a standby 0
    pmset -a autopoweroff 0
    pmset -a powernap 0
    pmset -a proximitywake 0
    pmset -a ttyskeepawake 1
    pmset -a tcpkeepalive 1
    pmset -a womp 1
  '';

  # Shells
  environment.shells = with pkgs; [ bash zsh fish ];
  programs.fish.enable = true;
  users.users.dm = {
    name = "dm";
    home = "/Users/dm";
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8zyMqlC1LHHWWk0v/wdfaVGYBoZSvD64xaAQZ5dOYh"
    ];
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
