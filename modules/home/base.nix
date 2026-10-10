# Shared user baseline: shell, git, ssh, terminal tooling.
# Deliberately does NOT manage ~/.claude - Claude Code rewrites its own config,
# and making it read-only is what caused most of cm01's friction.
{ pkgs, lib, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  onePasswordAgent = "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock";
in {

  imports = [
    ../../nvim
  ];

  home.stateVersion = "25.11";
  home.homeDirectory = if isDarwin then "/Users/dm" else "/home/dm";
  home.username = "dm";

  # User-level packages
  home.packages = with pkgs; [
    lazygit
    tldr
  ];

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # Git
  programs.git = {
    enable = true;
    lfs.enable = true;
    signing.format = null;
    settings = {
      user = {
        name = "Dave Murray";
        email = "github@mrry.io";
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      rebase.autoStash = true;
      merge.conflictstyle = "diff3";
      diff.algorithm = "histogram";
      diff.colorMoved = "default";
      rerere.enabled = true;
      column.ui = "auto";
      branch.sort = "-committerdate";
      fetch.prune = true;
    };
  };

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true;
      dark = true;
      line-numbers = true;
      syntax-theme = "ansi";
    };
  };

  # GitHub CLI. SSH for git; the credential helper only covers stray HTTPS remotes
  programs.gh = {
    enable = true;
    gitCredentialHelper.enable = true;
    settings = {
      git_protocol = "ssh";
      prompt = "enabled";
      aliases = {
        co = "pr checkout";
      };
    };
  };

  # SSH - 1Password agent (macOS) + connection multiplexing. Linux hosts use
  # the agent forwarded from the Mac they're reached from.
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = lib.optionalAttrs isDarwin {
        IdentityAgent = ''"${onePasswordAgent}"'';
      } // {
        ControlMaster = "auto";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "10m";
        ServerAliveInterval = 30;
        ServerAliveCountMax = 5;
      };
      "github.com" = {
        User = "git";
        ControlMaster = "no";
      };
    } // lib.optionalAttrs isDarwin {
      # mDNS doesn't reach wired hosts reliably on this LAN (IGMP snooping)
      "im01" = {
        HostName = "172.19.0.119";
        User = "dm";
        ForwardAgent = "yes";
      };
    };
  };

  # Fish - primary interactive shell
  programs.fish = {
    enable = true;
    plugins = [
      { name = "autopair"; src = pkgs.fishPlugins.autopair.src; }
      { name = "done"; src = pkgs.fishPlugins.done.src; }
      { name = "puffer"; src = pkgs.fishPlugins.puffer.src; }
      { name = "sponge"; src = pkgs.fishPlugins.sponge.src; }
    ];
    shellAliases = {
      ns = "nslookup";
    };
    shellAbbrs = lib.optionalAttrs isDarwin {
      drs = "sudo darwin-rebuild switch --flake ~/.config/nix-darwin";
    };
    functions = {
      nslookup = ''
        set -l host $argv[1]
        set host (string replace -r '^https?://|^ftp://' "" $host)
        set host (string replace -r '/.*' "" $host)
        set host (string replace -r ':.*' "" $host)
        command nslookup $host $argv[2..]
      '';
      # sponge filter: drop only typos (127 = command not found). Everything
      # else that fails (ssh, Ctrl-C, builds) stays in history.
      sponge_filter_typo = ''
        test "$argv[2]" = 127
      '';
    };
    loginShellInit = ''
      # Fix nix-darwin PATH ordering - ensure nix binaries take priority
      if test -n "$__NIX_DARWIN_SET_ENVIRONMENT_DONE"
        fish_add_path --prepend --path /run/current-system/sw/bin
        fish_add_path --prepend --path $HOME/.nix-profile/bin
      end
    '';
    interactiveShellInit = ''
      set -g fish_greeting
      set -g sponge_filters sponge_filter_typo

      # Tokyo Night colors
      set -g fish_color_normal c0caf5
      set -g fish_color_command 7aa2f7
      set -g fish_color_keyword bb9af7
      set -g fish_color_quote 9ece6a
      set -g fish_color_redirection c0caf5
      set -g fish_color_end ff9e64
      set -g fish_color_error f7768e
      set -g fish_color_param 9d7cd8
      set -g fish_color_comment 565f89
      set -g fish_color_selection --background=283457
      set -g fish_color_search_match --background=283457
      set -g fish_color_operator 9ece6a
      set -g fish_color_escape bb9af7
      set -g fish_color_autosuggestion 565f89
      set -g fish_pager_color_progress 565f89
      set -g fish_pager_color_prefix 7aa2f7
      set -g fish_pager_color_completion c0caf5
      set -g fish_pager_color_description 565f89

      # Auto-attach to tmux on SSH sessions
      if status is-interactive; and test -n "$SSH_CONNECTION"; and not set -q TMUX
        tmux new-session -A -s main
      end

      # Homebrew, local bins, and repo scripts
      fish_add_path -g /opt/homebrew/bin ~/.local/bin ~/.config/nix-darwin/scripts

      ${lib.optionalString isDarwin ''set -gx SSH_AUTH_SOCK "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"''}
      set -gx RIPGREP_CONFIG_PATH "$HOME/.ripgreprc"
      set -gx EDITOR nvim
    '';
  };

  # Zsh - fallback (and the login shell until `chsh` to fish)
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    history = {
      size = 100000;
      save = 100000;
      ignoreAllDups = true;
      ignoreSpace = true;
      extended = true;
      share = true;
    };
    shellAliases = lib.optionalAttrs isDarwin {
      drs = "sudo darwin-rebuild switch --flake ~/.config/nix-darwin";
    };
    profileExtra = lib.optionalString isDarwin ''
      eval "$(/opt/homebrew/bin/brew shellenv zsh)"
    '';
    envExtra = ''
      export EDITOR='nvim'
      export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"
      ${lib.optionalString isDarwin ''export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"''}
      export PATH="$HOME/.local/bin:$HOME/.config/nix-darwin/scripts:$PATH"
    '';
  };

  # Prompt - works with both fish and zsh
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    enableFishIntegration = true;
    settings = {
      add_newline = true;

      character = {
        success_symbol = "[>](bold #7aa2f7)";
        error_symbol = "[>](bold #f7768e)";
      };

      hostname = {
        ssh_only = false;
        format = "[$hostname](#565f89) ";
      };

      username = {
        show_always = true;
        format = "[$user](#bb9af7) ";
      };

      directory = {
        truncation_length = 3;
        style = "bold #2ac3de";
      };

      git_branch = {
        symbol = " ";
        style = "#9ece6a";
      };

      git_status.style = "#e0af68";

      cmd_duration = {
        min_time = 2000;
        format = "took [$duration](bold #ff9e64) ";
      };

      golang = { symbol = " "; style = "#2ac3de"; };
      python = { symbol = " "; style = "#bb9af7"; };
      terraform = { symbol = " "; style = "#7aa2f7"; };
      nix_shell = { symbol = " "; style = "#7aa2f7"; };
    };
  };

  # bat - cat replacement with syntax highlighting
  programs.bat = {
    enable = true;
    config = {
      theme = "ansi";
      pager = "less -FR";
    };
  };

  # eza - ls replacement with git awareness
  programs.eza = {
    enable = true;
    git = true;
    icons = "auto";
    enableFishIntegration = true;
    enableZshIntegration = true;
  };

  # direnv - auto-activate per-project devShells
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    silent = true;
  };

  # tmux
  programs.tmux = {
    enable = true;
    keyMode = "vi";
    mouse = true;
    baseIndex = 1;
    escapeTime = 10;
    historyLimit = 50000;
    terminal = "tmux-256color";
    plugins = with pkgs.tmuxPlugins; [
      {
        plugin = tokyo-night-tmux;
        extraConfig = ''
          set -g @tokyo-night-tmux_window_id_style none
          set -g @tokyo-night-tmux_show_datetime 0
          set -g @tokyo-night-tmux_show_battery_widget 0
          set -g @tokyo-night-tmux_show_path 1
          set -g @tokyo-night-tmux_path_format relative
        '';
      }
      vim-tmux-navigator
      {
        plugin = resurrect;
        extraConfig = ''
          set -g @resurrect-capture-pane-contents 'on'
        '';
      }
      {
        plugin = continuum;
        extraConfig = ''
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '10'
        '';
      }
    ];
    extraConfig = ''
      set -g focus-events on
      set -g renumber-windows on
      setw -g aggressive-resize on

      # Ghostty extended keys support
      set -s extended-keys on
      set -as terminal-features 'xterm-ghostty:extkeys'

      # OSC52 clipboard - copy from remote tmux to local clipboard over SSH
      set -g set-clipboard on
    '';
  };

  # Ghostty (installed via Homebrew cask, config managed by HM)
  programs.ghostty = {
    enable = isDarwin; # GUI terminal; Linux hosts only need its terminfo
    package = null;
    enableFishIntegration = true;
    settings = {
      font-family = "FiraCode Nerd Font";
      font-size = 13;
      theme = "TokyoNight Night";
      window-padding-x = 12;
      window-padding-y = 8;
      window-padding-balance = true;
      macos-titlebar-style = "transparent";
      macos-titlebar-proxy-icon = "hidden";
      title = " "; # blank titlebar text (empty string would reset to default)
      confirm-close-surface = false;
      copy-on-select = "clipboard";
      cursor-style = "block";
      mouse-hide-while-typing = true;
      scrollback-limit = 50000;
    };
  };

  # zoxide - smart cd
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };

  # fzf
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
    enableFishIntegration = true;
    defaultOptions = [
      "--height=40%"
      "--layout=reverse"
      "--border"
      "--color=bg+:#283457,bg:#1a1b26,spinner:#bb9af7,hl:#7aa2f7"
      "--color=fg:#c0caf5,header:#7aa2f7,info:#e0af68,pointer:#bb9af7"
      "--color=marker:#9ece6a,fg+:#c0caf5,prompt:#bb9af7,hl+:#7aa2f7"
    ];
  };

  # Silence "Last login" message
  home.file.".hushlogin".text = "";

  # ripgrep
  home.file.".ripgreprc".text = ''
    --smart-case
    --hidden
    --glob=!.git
    --glob=!node_modules
    --glob=!.direnv
    --glob=!result
  '';
}
