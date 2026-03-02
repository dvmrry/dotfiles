# nix-darwin

Declarative macOS system config for a2337 (MacBook Air M1, headless devbox).

## Rebuild

```bash
sudo darwin-rebuild switch --flake ~/.config/nix-darwin
```

## Bootstrap on fresh install

1. Install Nix (Determinate Systems installer)
2. Install Homebrew
3. Clone this repo to `~/.config/nix-darwin/`
4. Run the rebuild command above
5. Restore sops age key from 1Password:

```bash
mkdir -p ~/.config/sops/age
op read "op://Private/talos/sops-age-key" > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

## Nix store maintenance

GC and optimise must be run manually (Determinate installer manages the nix daemon):

```bash
nix-collect-garbage --delete-older-than 14d
nix store optimise
```

## Notes

- `nix.enable = false` because Determinate Systems installer manages the nix daemon
- Flake files must be `git add`ed before `darwin-rebuild` can see them
- Commit `flake.lock` -- it pins your exact nixpkgs revision
