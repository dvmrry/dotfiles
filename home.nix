{ pkgs, lib, inputs, ... }: {

  imports = [
    ./nvim
  ];

  home.stateVersion = "24.11";
  home.homeDirectory = "/Users/dm";
  home.username = "dm";

  # User-level packages
  home.packages = with pkgs; [
    lazygit
    nix-zsh-completions
    tldr
    zsh-completions
  ];

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # Git
  programs.git = {
    enable = true;
    lfs.enable = true;
    delta = {
      enable = true;
      options = {
        navigate = true;
        dark = true;
        line-numbers = true;
        syntax-theme = "ansi";
      };
    };
    extraConfig = {
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

  # GitHub CLI
  programs.gh = {
    enable = true;
    gitCredentialHelper.enable = true;
    settings = {
      git_protocol = "https";
      prompt = "enabled";
      aliases = {
        co = "pr checkout";
      };
    };
  };

  # SSH - 1Password agent + connection multiplexing
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      "*" = {
        extraOptions = {
          IdentityAgent = ''"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"'';
          ControlMaster = "auto";
          ControlPath = "~/.ssh/master-%r@%n:%p";
          ControlPersist = "10m";
          ServerAliveInterval = "30";
          ServerAliveCountMax = "5";
        };
      };
      "github.com" = {
        extraOptions.ControlMaster = "no";
        user = "git";
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
      vi = "nvim";
      k = "kubecolor";
      tf = "tofu";
    };
    shellAbbrs = {
      # Kubernetes
      kgd = "kubecolor get deploy";
      kgk = "kubecolor get kustomizations --all-namespaces";
      kgp = "kubecolor get pods";
      kgpv = "kubecolor get pv";
      kgpvc = "kubecolor get pvc";
      kgs = "kubecolor get services";
      kpf = "kubecolor port-forward";
      kctx = "kubectx";
      kns = "kubens";

      # Terraform / OpenTofu
      tfa = "tofu apply";
      tfi = "tofu init";
      tfp = "tofu plan";
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

      # Homebrew & local bins
      fish_add_path -g /opt/homebrew/bin ~/.local/bin

      # 1Password SSH agent
      set -gx SSH_AUTH_SOCK "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
      set -gx SOPS_AGE_KEY_FILE "$HOME/.config/sops/age/keys.txt"
      set -gx RIPGREP_CONFIG_PATH "$HOME/.ripgreprc"
      set -gx EDITOR nvim

      # 1Password service account (sops-encrypted, headless over SSH)
      if not set -q OP_SERVICE_ACCOUNT_TOKEN; and command -q sops; and test -f "$SOPS_AGE_KEY_FILE"
        set -gx OP_SERVICE_ACCOUNT_TOKEN (sops --decrypt --extract '["op_service_account_token"]' ~/.config/nix-darwin/secrets/op.yaml 2>/dev/null)
      end

      # Tool completions - cached to avoid slow generation on every shell start
      set -l comp_dir ~/.cache/fish/generated_completions
      mkdir -p $comp_dir
      for tool in kubectl helm flux talosctl
        if not test -f $comp_dir/$tool.fish
          command $tool completion fish > $comp_dir/$tool.fish 2>/dev/null &
        end
      end
      for f in $comp_dir/*.fish
        source $f 2>/dev/null
      end
      complete -c kubecolor -w kubectl
      complete -c k -w kubectl
    '';
  };

  # Zsh - fallback
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    completionInit = "autoload -U compinit && compinit -i";
    autosuggestion = {
      enable = true;
      strategy = [ "history" "completion" ];
    };
    syntaxHighlighting.enable = true;
    history = {
      size = 100000;
      save = 100000;
      ignoreAllDups = true;
      ignoreDups = true;
      ignoreSpace = true;
      extended = true;
      share = true;
    };
    shellAliases = {
      vi = "nvim";
      k = "kubecolor";
      kgd = "kubecolor get deploy";
      kgk = "kubecolor get kustomizations --all-namespaces";
      kgp = "kubecolor get pods";
      kgpv = "kubecolor get pv";
      kgpvc = "kubecolor get pvc";
      kgs = "kubecolor get services";
      kpf = "kubecolor port-forward";
      kctx = "kubectx";
      kns = "kubens";
      tf = "tofu";
      tfa = "tofu apply";
      tfi = "tofu init";
      tfp = "tofu plan";
    };
    initContent = ''
      source <(kubectl completion zsh)
      compdef kubecolor=kubectl
      complete -F __start_kubectl k
      eval "$(op completion zsh)"; compdef _op op
      export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
      zstyle ':completion:*' menu select
      zstyle ':completion:*' verbose yes
      zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
      zstyle ':completion:*' list-colors ""
      zstyle ':completion:*:descriptions' format '%F{green}-- %d --%f'
      zstyle ':completion:*:warnings' format '%F{red}-- no matches --%f'
      zstyle ':completion:*' group-name ""
      zstyle ':completion:*:manuals' separate-sections true
      zstyle ':completion:*:options' description yes
      zstyle ':completion:*:options' auto-description '%d'
      if command -v fzf &>/dev/null; then
        source <(fzf --zsh)
      fi
    '';
    envExtra = ''
      export EDITOR='nvim'
      export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"
      export PATH="$HOME/.local/bin:$PATH"
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

      kubernetes = {
        disabled = false;
        symbol = " ";
        format = "[$symbol$context( \\($namespace\\))](dimmed #7aa2f7) ";
      };

      cmd_duration = {
        min_time = 2000;
        format = "took [$duration](bold #ff9e64) ";
      };

      golang = { symbol = " "; style = "#2ac3de"; };
      python = { symbol = " "; style = "#bb9af7"; };
      terraform = { symbol = " "; style = "#7aa2f7"; };
      nix_shell = { symbol = " "; style = "#7aa2f7"; };
      aws.disabled = false;
      gcloud.disabled = false;
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

  # Go
  programs.go = {
    enable = true;
    telemetry.mode = "off";
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
          set -g @resurrect-strategy-nvim 'session'
          set -g @resurrect-capture-pane-contents 'on'
        '';
      }
      {
        plugin = continuum;
        extraConfig = ''
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '10'
          set -g @continuum-boot 'on'
        '';
      }
    ];
    extraConfig = ''
      # Focus events for vim integration
      set -g focus-events on

      # Renumber windows when one is closed
      set -g renumber-windows on

      # Aggressive resize for multiple clients
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
    enable = true;
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

  # Claude Code - settings managed declaratively
  home.file.".claude/settings.json".source = ./claude/settings.json;
  home.file.".claude/hooks/notify-sudo.sh" = {
    source = ./claude/notify-sudo.sh;
    executable = true;
  };

  # Claude Code - post-activation plugin setup
  home.activation.claudePlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if command -v claude &>/dev/null; then
      # Add superpowers marketplace if not present
      if [ ! -d "$HOME/.claude/plugins/marketplaces/superpowers-marketplace" ]; then
        claude /plugin marketplace add obra/superpowers-marketplace 2>/dev/null || true
      fi
      # Install superpowers if not present
      claude /plugin install superpowers@superpowers-marketplace 2>/dev/null || true
    fi
  '';

  # Silence "Last login" message
  home.file.".hushlogin".text = "";

  # Headless health check script
  home.file.".local/bin/health" = {
    executable = true;
    text = ''
      #!/bin/sh
      echo "=== Uptime ==="
      uptime

      echo "\n=== Disk Usage ==="
      df -H / /nix

      echo "\n=== Memory Pressure ==="
      memory_pressure | head -3

      echo "\n=== Nix Store ==="
      du -sh /nix/store 2>/dev/null

      echo "\n=== Power Management ==="
      pmset -g | grep -E 'sleep|standby|autopoweroff'

      echo "\n=== Recent Wake/Sleep ==="
      pmset -g log 2>/dev/null | grep -E "Wake|Sleep" | tail -5

      echo "\n=== SSH Sessions ==="
      who

      echo "\n=== tmux Sessions ==="
      tmux list-sessions 2>/dev/null || echo "No tmux sessions"
    '';
  };

  # ripgrep
  home.file.".ripgreprc".text = ''
    --smart-case
    --hidden
    --glob=!.git
    --glob=!node_modules
    --glob=!.direnv
    --glob=!result
  '';

  # Vim
  home.file.".vimrc".text = ''
    filetype plugin indent on
    set tabstop=4
    set shiftwidth=4
    set expandtab
  '';
}
