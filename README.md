# nix-darwin

Declarative macOS config (nix-darwin + Home Manager, flake-based) for multiple hosts.

| Host   | Machine            | Layout                                      |
|--------|--------------------|---------------------------------------------|
| `cm01` | MacBook Air M1     | `hosts/cm01/` (legacy, self-contained)      |
| `cm02` | Mac Mini M6        | `modules/{darwin,home}/base.nix` + `hosts/cm02/` |

## Layout

```
flake.nix
modules/darwin/base.nix   # shared system baseline (role-agnostic)
modules/home/base.nix     # shared user baseline (shell, git, ssh, tmux, ...)
hosts/<name>/             # per-host bits; import role modules here
hosts/cm01/               # cm01's original configuration.nix + home.nix
nvim/ claude/ scripts/ secrets/   # shared assets
```

## Rebuild

```bash
sudo darwin-rebuild switch --flake ~/.config/nix-darwin
```

The flake output is picked by hostname. Before the first rebuild sets it, name it explicitly: `--flake ~/.config/nix-darwin#cm02`.

## Bootstrap on fresh install

1. Install Homebrew
2. Install the 1Password app, sign in, enable the SSH agent and CLI integration
3. Install Nix (Determinate Systems installer)
4. `nix run nixpkgs#gh -- auth login`
5. Clone this repo to `~/.config/nix-darwin/`
6. `sudo nix run nix-darwin -- switch --flake ~/.config/nix-darwin#<host>`
7. Optional: `chsh -s /run/current-system/sw/bin/fish`

Restore the sops age key from 1Password (needed for `secrets/`):

```bash
mkdir -p ~/.config/sops/age
op read "op://Private/talos/sops-age-key" > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

## Notes

- Determinate manages the nix daemon and GC (`determinateNix` module)
- Flake files must be `git add`ed before `darwin-rebuild` can see them
- Commit `flake.lock` -- it pins your exact nixpkgs revision
- Homebrew doesn't auto-update/upgrade on rebuild; run `brew update && brew upgrade` when you want it
