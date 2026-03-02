{ config, lib, inputs, pkgs, ... }: {
  imports = [
    inputs.nixCats.homeModule
  ];

  config.nixCats = {
    enable = true;
    packageNames = [ "nvim" ];
    luaPath = ./.;

    categoryDefinitions.replace = { pkgs, ... }: {

      lspsAndRuntimeDeps = {
        general = with pkgs; [
          ripgrep
          fd
        ];
        go = with pkgs; [
          gopls
          delve
          gotools
        ];
        nix = with pkgs; [
          nil
          nixfmt-rfc-style
        ];
        python = with pkgs; [
          pyright
          ruff
        ];
        terraform = with pkgs; [
          terraform-ls
        ];
        typescript = with pkgs; [
          typescript-language-server
        ];
        yaml = with pkgs; [
          yaml-language-server
        ];
      };

      startupPlugins = {
        general = with pkgs.vimPlugins; [
          catppuccin-nvim
          vim-sleuth
        ];
      };

      optionalPlugins = {
        general = with pkgs.vimPlugins; [
          blink-cmp
          conform-nvim
          gitsigns-nvim
          lualine-nvim
          nvim-lspconfig
          nvim-treesitter.withAllGrammars
          oil-nvim
          telescope-nvim
          telescope-fzf-native-nvim
          which-key-nvim
        ];
        claude = with pkgs.vimPlugins; [
          claudecode-nvim
          snacks-nvim
        ];
      };

      sharedLibraries = { };
      environmentVariables = { };
      extraWrapperArgs = { };
    };

    packageDefinitions.replace = {
      nvim = { pkgs, ... }: {
        settings = {
          wrapRc = true;
          aliases = [ "vim" "vi" ];
          suffix-path = true;
        };
        categories = {
          general = true;
          claude = true;
          go = true;
          nix = true;
          python = true;
          terraform = true;
          typescript = true;
          yaml = true;
        };
      };
    };
  };
}
