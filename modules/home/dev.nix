# Baseline toolchains for work outside a project devShell. Project-specific
# versions belong in that repo's flake.nix (loaded by direnv), not here.
{ pkgs, ... }: {
  home.packages = with pkgs; [
    go
    rustup # run `rustup default stable` once to install a toolchain
    gnumake
    pkg-config
    cmake
    ninja
    just

    # Go: lint/format for any module (a repo that pins its own versions in
    # tools/go.mod, like zscalerctl, uses those through `go tool`)
    golangci-lint
    gofumpt

    # JS/TS: Bun, tsc, and Biome (single-binary lint + format)
    bun
    typescript
    biome

    # Nix and shell linters/formatters (this repo's pre-commit hooks use them)
    deadnix
    nixfmt
    shfmt
    statix

    # Deterministic code tooling (for people and coding agents): structural
    # search/rewrite over syntax trees, structural diffs, line counts by
    # language, benchmarks, rerun-on-change, and GitHub Actions/TOML linters
    actionlint
    ast-grep
    difftastic
    hyperfine
    taplo
    tokei
    watchexec

    # Checks an agent's work when its turn ends: a repo's own scripts/check-fast
    # and the default per-language checks in claude/check-default. The Claude
    # Code hooks (`agent-check hook`, `prompt`, `snap`) and the report appended
    # to dispatched workers' output (`agent-check run DIR`). The default checks'
    # tools are pinned here, so tier 0 never runs a repo's own copies.
    (writeShellApplication {
      name = "agent-check";
      runtimeInputs = [
        bash
        coreutils
        diffutils
        findutils
        gawk
        git
        gnugrep
        gnused
        jq
        # The default checks' tools
        biome
        bun
        gitleaks
        typescript
      ];
      text = ''
        export AGENT_CHECK_LIB=${../../claude/check-default}
      ''
      + builtins.readFile ../../claude/agent-check.sh;
    })
  ];

  # Where `go install` and `cargo install` put binaries
  home.sessionPath = [
    "$HOME/go/bin"
    "$HOME/.cargo/bin"
  ];

  # Short names for our own CLIs, installed into ~/go/bin by their `make install`
  programs.fish.shellAbbrs.plx = "prolexic"; # github.com/dvmrry/akamai-prolexic
  programs.zsh.shellAliases.plx = "prolexic";
}
