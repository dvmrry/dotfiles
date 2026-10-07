# Shared system baseline: role-agnostic, safe on any Mac.
# Role-specific bits (headless power, yabai/skhd, media, homelab tools) belong
# in their own modules, imported per host.
{ pkgs, ... }: {

  # Packages installed system-wide. Language toolchains and infra CLIs are
  # better pinned per project via direnv + devShells than added here.
  environment.systemPackages = with pkgs; [
    # Core tools
    age
    curl
    fd
    fzf
    gnupg
    httpie
    jq
    mosh
    ripgrep
    shellcheck
    tree
    watch
    wget
    yq

    # System monitoring
    btop
    macmon

    # Languages & runtimes
    nodejs
    python3
    uv

    # Git
    git
    git-lfs

    # Nix helpers
    nh
  ];

  # Enable Touch ID for sudo (reattach fixes Touch ID inside tmux)
  security.pam.services.sudo_local.touchIdAuth = true;
  security.pam.services.sudo_local.reattach = true;

  # Pinned SSH host keys (from https://api.github.com/meta)
  programs.ssh.knownHosts.github = {
    hostNames = [ "github.com" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
  };

  # Homebrew - GUI apps and things that should self-update
  homebrew = {
    enable = true;
    onActivation = {
      # Rebuilds stay fast and predictable; run `brew update && brew upgrade` deliberately.
      autoUpdate = false;
      upgrade = false;
      # "none" while this machine's role is still settling, so an ad-hoc
      # `brew install` isn't silently removed on the next rebuild.
      # Tighten to "uninstall" once the cask list is stable.
      cleanup = "none";
    };
    casks = [
      "1password"
      # From brew rather than nixpkgs: the 1Password app's CLI integration
      # expects `op` at a stable path outside the nix store.
      "1password-cli"
      # From brew rather than nixpkgs: tracks releases closely and self-updates.
      "claude-code"
      "font-fira-code-nerd-font"
      "ghostty"
    ];
  };

  # macOS system defaults
  system.defaults = {
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
    loginwindow.GuestEnabled = false;
    menuExtraClock = {
      Show24Hour = true;
      ShowSeconds = false;
    };
    screencapture = {
      type = "png";
      disable-shadow = true;
    };
    screensaver = {
      askForPassword = true;
      askForPasswordDelay = 0;
    };
    NSGlobalDomain = {
      AppleShowAllExtensions = true;
      AppleInterfaceStyle = "Dark";
      AppleKeyboardUIMode = 3; # full keyboard access
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
    };
  };

  # Reload preferences so most defaults apply without logging out
  system.activationScripts.postActivation.text = ''
    sudo -u dm /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';

  # Shells. The login shell is NOT set here: nix-darwin only applies
  # users.users.<name>.shell for users in users.knownUsers, which must not
  # include admin accounts. Run once instead:
  #   chsh -s /run/current-system/sw/bin/fish
  environment.shells = with pkgs; [ bash zsh fish ];
  programs.fish.enable = true;
  users.users.dm = {
    name = "dm";
    home = "/Users/dm";
  };

  # Primary user for per-user system defaults and Homebrew
  system.primaryUser = "dm";

  # Nix - managed by Determinate
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

  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-darwin";

  # Used for backwards compatibility
  system.stateVersion = 6;
}
