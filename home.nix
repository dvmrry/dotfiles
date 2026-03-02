{ pkgs, lib, ... }: {

  home.stateVersion = "24.11";
  home.homeDirectory = "/Users/dm";
  home.username = "dm";

  # User-level packages
  home.packages = with pkgs; [
    htop
    tldr
    zsh-completions
    nix-zsh-completions
  ];

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # Git
  programs.git = {
    enable = true;
    lfs.enable = true;
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
      rerere.enabled = true;
      column.ui = "auto";
      branch.sort = "-committerdate";
      fetch.prune = true;
    };
  };

  # GitHub CLI
  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "ssh";
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

      # Homebrew & local bins
      fish_add_path -g /opt/homebrew/bin ~/.local/bin

      # 1Password SSH agent
      set -gx SSH_AUTH_SOCK "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
      set -gx EDITOR nvim

      # Tool completions
      kubectl completion fish | source
      complete -c kubecolor -w kubectl
      complete -c k -w kubectl
      helm completion fish | source
      flux completion fish | source
      talosctl completion fish | source
      op completion fish | source
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
        success_symbol = "[>](bold green)";
        error_symbol = "[>](bold red)";
      };

      hostname = {
        ssh_only = false;
        format = "[$hostname]($style) ";
      };

      username = {
        show_always = true;
        format = "[$user]($style) ";
      };

      directory = {
        truncation_length = 3;
        style = "bold cyan";
      };

      git_branch.symbol = " ";

      kubernetes = {
        disabled = false;
        symbol = " ";
        format = "[$symbol$context( \\($namespace\\))](dimmed green) ";
      };

      cmd_duration = {
        min_time = 2000;
        format = "took [$duration](bold yellow) ";
      };

      golang.symbol = " ";
      python.symbol = " ";
      terraform.symbol = " ";
      aws.disabled = false;
      gcloud.disabled = false;
    };
  };

  # bat - cat replacement with syntax highlighting
  programs.bat = {
    enable = true;
    config = {
      theme = "TwoDark";
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
    historyLimit = 10000;
    plugins = with pkgs.tmuxPlugins; [
      vim-tmux-navigator
      {
        plugin = resurrect;
        extraConfig = "set -g @resurrect-strategy-nvim 'session'";
      }
      {
        plugin = continuum;
        extraConfig = ''
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '10'
        '';
      }
    ];
  };

  # fzf
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
    enableFishIntegration = true;
    defaultOptions = [ "--height=40%" "--layout=reverse" "--border" ];
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

  # Vim
  home.file.".vimrc".text = ''
    filetype plugin indent on
    set tabstop=4
    set shiftwidth=4
    set expandtab
  '';
}
