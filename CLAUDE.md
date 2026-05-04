# nix-darwin config

This is Dave's headless macOS dev environment (cm01, MacBook Air M1), managed declaratively via nix-darwin + Home Manager (flake-based).

## The one rule

**Everything is declarative.** No `brew install`, no `claude plugin marketplace add`, no `pip install`, no manual edits to `~/.claude/*` files, no editing `/etc/sudoers` directly. If a change can't be expressed in `configuration.nix`, `home.nix`, or files under this repo, **stop and flag it** — don't reach for the imperative shortcut.

There is one known mutable-state gap: marketplace registration for Claude Code plugins (see below). Don't introduce new gaps without explicit signoff.

## Apply changes

`drs` — alias for `sudo darwin-rebuild switch --flake ~/.config/nix-darwin`. Passwordless sudo is wired for this command only.

## Where things live

- `configuration.nix` — system-level: packages, casks (Homebrew via nix-darwin), sudo rules, system defaults.
- `home.nix` — user-level: shell, git, tmux, Claude Code config, MCPs, skills, hooks.
- `scripts/` — wrapper scripts referenced from Nix (e.g. `scripts/bambuddy-mcp-wrapper`). Added to PATH.
- `claude/skills/cw-*` — local skill dirs symlinked via `home.file`.
- `secrets/*.yaml` — sops-encrypted (age key).

## Adding things

### Skills
- **Local skill** (lives in this repo): drop the dir under `claude/skills/<name>/` and add a `home.file.".claude/skills/<name>" = { source = ./claude/skills/<name>; recursive = true; };` entry.
- **Upstream skill** (from a GitHub repo): add a `pkgs.fetchFromGitHub` to the `let` block at the top of `home.nix` (pinned `rev` + `sha256`), then `home.file.".claude/skills/<name>".source = "${src}/path/to/skill";`. See the `mattpocock-skills` block for the pattern. Get sha256 with: `nix-prefetch-url --unpack https://github.com/<owner>/<repo>/archive/<rev>.tar.gz`.

### MCP servers
**Go in `home.file.".claude/mcp.json"`, NOT `programs.claude-code.settings.mcpServers`.** Claude Code reads from `mcp.json`, not from `settings.json`. We've made this mistake before.

### Plugins from a real marketplace
Add to `programs.claude-code.settings.enabledPlugins` in `home.nix` as `"<plugin>@<marketplace>" = true;`. The marketplace itself must already be registered via `claude plugin marketplace add <source>` — that step is the one mutable-state gap; the registration sits in `~/.claude/plugins/known_marketplaces.json`. Don't try to write that file via `home.file` — Claude Code rewrites it.

### Hooks
Hook `command` strings must be prefixed with `bash` (e.g. `"bash ~/.claude/hooks/foo.sh"`). Files in the nix store are `r--r--r--` (no execute bit), so direct invocation fails with a `PreToolUse:Bash hook error`.

## Gotchas (don't relearn these)

- **`security.sudo.extraRules` doesn't exist in nix-darwin.** Use `security.sudo.extraConfig` with raw sudoers syntax. (NixOS has `extraRules`; nix-darwin doesn't.)
- **Home Manager 25.05 git signing**: `programs.git.signing.format` must be set at the module level, NOT inside `programs.git.settings`. Setting it inside `settings` fails type-check.
- **macOS `grep -P` doesn't work** — use `sed` for regex extraction in any script that needs to run here.
- **Plugin install via `claude plugin install`** writes to `settings.json`, which is nix-managed (read-only). Use `enabledPlugins` in `home.nix` instead.
- **`uv` and `uvx`** are installed system-wide via `configuration.nix`. Use `uv run --project <path>` to invoke project-local CLIs.

## Commits

No `Co-Authored-By` lines. Short, conventional-ish messages (`fix:`, `feat:`, `docs:`).
