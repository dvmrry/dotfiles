# Baseline toolchains for work outside a project devShell. Project-specific
# versions belong in that repo's flake.nix (loaded by direnv), not here.
{ pkgs, ... }: {
  home.packages = with pkgs; [
    go
    rustup # run `rustup default stable` once to install a toolchain
    gnumake
    pkg-config
    cmake
    just
  ];

  # Where `go install` and `cargo install` put binaries
  home.sessionPath = [
    "$HOME/go/bin"
    "$HOME/.cargo/bin"
  ];
}
