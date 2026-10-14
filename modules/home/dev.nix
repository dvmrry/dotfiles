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
