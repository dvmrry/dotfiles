# nix-darwin config

Dave's macOS machines, managed via nix-darwin + Home Manager (flake-based):

- `cm01` — MacBook Air M1, headless devbox. Self-contained under `hosts/cm01/` (legacy layout).
- `cm02` — Mac Mini M6, role still settling. Built from `modules/*/base.nix` + `hosts/cm02/`.

## The rule

**Nix owns the slow-moving basics; apps own their own state.**

- Declarative: system packages, macOS defaults, Homebrew cask list, shell/git/ssh/tmux/terminal config.
- Not Nix-managed: anything an app rewrites itself. In particular **`~/.claude` is not managed on `cm02`** — Claude Code settings, plugins, marketplaces and MCPs are configured with `claude` itself. (On cm01, HM made `settings.json` read-only, which broke `claude plugin install` and forced workarounds; don't reintroduce that.)
- If an app-written config should be version-controlled, use `config.lib.file.mkOutOfStoreSymlink` to point at a file in this repo (stays writable) rather than `home.file.<x>.text`/`source` (read-only store copy). Verify the app doesn't replace the symlink with a regular file on save.
- Prefer per-project devShells (direnv) over adding language toolchains / infra CLIs to the base.

## Apply changes

`drs` — alias for `sudo darwin-rebuild switch --flake ~/.config/nix-darwin`.

## Where things live

- `modules/darwin/base.nix` — shared system baseline. Must stay role-agnostic.
- `modules/home/base.nix` — shared user baseline.
- `hosts/<name>/` — host-specific settings; role modules (headless, window manager, media, ...) get imported here.
- `hosts/cm01/` — cm01's original monolithic config. Not yet migrated onto `modules/`.
- `scripts/` — wrapper scripts, on PATH.
- `claude/skills/cw-*` — local skill dirs (used by cm01).
- `secrets/*.yaml` — sops-encrypted (age key), cm01 only.

## Gotchas (don't relearn these)

- **Homebrew cleanup**: `cm02` uses `cleanup = "none"`; cm01 uses `"zap"`, which removes any cask/brew not listed — including ones installed by hand.
- **Login shell**: `users.users.<name>.shell` is only applied for users in `users.knownUsers`, which must not contain admin accounts. Use `chsh` once.
- **`security.sudo.extraRules` doesn't exist in nix-darwin.** Use `security.sudo.extraConfig` with raw sudoers syntax.
- **Home Manager git signing**: `programs.git.signing.format` is set at the module level, not inside `programs.git.settings`.
- **Hooks / scripts in the nix store** have no execute bit — invoke via `bash <path>`.
- **macOS `grep -P` doesn't work** — use `sed` for regex extraction.
- **mDNS renames** (`cm02-2`, `cm02 (2)`): macOS renames itself when it sees its own name on the LAN (Wi-Fi + Ethernet on the same network, Bonjour Sleep Proxy). `modules/darwin/pin-hostname.nix` reverts it; check `/var/log/pin-hostname.log`. Frequent entries mean a real cause worth fixing.
- **MCP servers (cm01)**: were written to `~/.claude/mcp.json` via HM. On `cm02`, add them with `claude mcp add` instead.

## Commits

No `Co-Authored-By` lines. Short, conventional-ish messages (`fix:`, `feat:`, `docs:`).
