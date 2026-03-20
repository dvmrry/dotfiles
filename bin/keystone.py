#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["rich", "pyyaml"]
# ///
"""
Keystone — multi-cloud auth manager
Azure + AWS SSO with PIM activation.
Reads ~/.config/keystone/config.yaml (same schema as the Go app).

Usage:
    uv run keystone.py               # interactive TUI dashboard
    uv run keystone.py login         # login all enabled tenants
    uv run keystone.py login ALDN    # login single tenant
    uv run keystone.py check         # check token freshness
    uv run keystone.py refresh       # silent token refresh (no browser)
"""

import argparse
import atexit
import base64
import http.server
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import yaml

try:
    from rich.console import Console
    from rich.live import Live
    from rich.spinner import Spinner
    from rich.table import Table
    from rich.panel import Panel
    from rich.prompt import Prompt
    from rich.text import Text
    from rich import print as rprint
except ImportError:
    print("Missing dependency: pip install rich pyyaml", file=sys.stderr)
    sys.exit(1)

console = Console()

EDGE = "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
CONFIG_PATH = Path.home() / ".config" / "keystone" / "config.yaml"


# — Config ——————————————————————————————————————————————————————————————

@dataclass
class PIMConfig:
    role: str = ""
    role_guid: str = ""
    subscription: str = ""
    duration: str = "PT4H"
    reason: str = ""
    claims_b64: str = ""


@dataclass
class Tenant:
    name: str
    provider: str = "azure"
    enabled: bool = True
    # Azure
    tenant_id: str = ""
    config_dir: str = ""
    pim: Optional[PIMConfig] = None
    pims: list = field(default_factory=list)  # multiple PIM roles
    # AWS SSO
    profile: str = ""
    sso_start_url: str = ""
    sso_region: str = ""


def expand(path: str) -> str:
    return str(Path(path).expanduser()) if path else ""


def _parse_pim(pim_raw: dict) -> PIMConfig:
    return PIMConfig(**{k: v for k, v in pim_raw.items() if k in PIMConfig.__dataclass_fields__})


def load_config() -> tuple[dict, list[Tenant]]:
    if not CONFIG_PATH.exists():
        console.print(f"[red]Config not found:[/] {CONFIG_PATH}")
        sys.exit(1)
    raw = yaml.safe_load(CONFIG_PATH.read_text())
    tenants = []
    for t in raw.get("tenants", []):
        pim_raw = t.get("pim")
        pim = _parse_pim(pim_raw) if pim_raw else None
        pims_raw = t.get("pims", [])
        pims = [_parse_pim(p) for p in pims_raw]
        tenants.append(Tenant(
            name=t["name"],
            provider=t.get("provider", "azure"),
            enabled=t.get("enabled", True),
            tenant_id=t.get("tenant_id", ""),
            config_dir=expand(t.get("config_dir", "")),
            pim=pim,
            pims=pims,
            profile=t.get("profile", ""),
            sso_start_url=t.get("sso_start_url", ""),
            sso_region=t.get("sso_region", ""),
        ))
    return raw, tenants


def apply_env(cfg: dict):
    """Apply proxy/CA env vars from config, ensure Homebrew in PATH."""
    proxy = cfg.get("https_proxy", "")
    if proxy:
        os.environ["HTTPS_PROXY"] = proxy
        os.environ["https_proxy"] = proxy
    ca = expand(cfg.get("ca_bundle", ""))
    if ca:
        os.environ["REQUESTS_CA_BUNDLE"] = ca
        os.environ["SSL_CERT_FILE"] = ca
        os.environ["CURL_CA_BUNDLE"] = ca
    # Ensure Homebrew tools (az, aws) are findable when run outside shell.
    for p in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]:
        if p not in os.environ.get("PATH", ""):
            os.environ["PATH"] = p + ":" + os.environ.get("PATH", "")


# — Token freshness ————————————————————————————————————————————————————

def _az_env(t: Tenant) -> dict:
    env = os.environ.copy()
    if t.config_dir:
        env["AZURE_CONFIG_DIR"] = t.config_dir
    return env


def _token_secs_left_azure(t: Tenant) -> int:
    if not t.config_dir:
        return 0
    cache = Path(t.config_dir) / "msal_token_cache.json"
    if not cache.exists():
        return 0
    try:
        data = json.loads(cache.read_text())
        best = 0
        for tok in data.get("AccessToken", {}).values():
            tid = tok.get("realm", "")
            if t.tenant_id and tid and tid.lower() != t.tenant_id.lower():
                continue
            exp = int(tok.get("expires_on", 0))
            left = exp - int(time.time())
            if left > best:
                best = left
        return max(0, best)
    except Exception:
        return 0


def _token_secs_left_aws(t: Tenant) -> int:
    if not t.sso_start_url:
        return 0
    sso_cache = Path.home() / ".aws" / "sso" / "cache"
    if not sso_cache.exists():
        return 0
    best = 0
    for f in sso_cache.glob("*.json"):
        try:
            d = json.loads(f.read_text())
            if d.get("startUrl", "") != t.sso_start_url:
                continue
            exp_str = d.get("expiresAt", "")
            if not exp_str:
                continue
            from datetime import datetime, timezone
            exp = datetime.fromisoformat(exp_str.replace("Z", "+00:00"))
            left = int((exp - datetime.now(timezone.utc)).total_seconds())
            if left > best:
                best = left
        except Exception:
            continue
    return max(0, best)


def token_secs_left(t: Tenant) -> int:
    if t.provider == "azure":
        return _token_secs_left_azure(t)
    elif t.provider == "aws-sso":
        return _token_secs_left_aws(t)
    return 0


def fmt_duration(secs: int) -> str:
    if secs <= 0:
        return "expired"
    h, rem = divmod(secs, 3600)
    m = rem // 60
    if h:
        return f"{h}h {m}m"
    return f"{m}m"


# — Status callback helper —————————————————————————————————————————————

def _make_status_cb(status_cb=None):
    """Return a status function that uses the callback or prints dim."""
    def status(msg):
        if status_cb:
            status_cb(msg)
        else:
            console.print(f"  [dim]{msg}[/]")
    return status


# — Browser proxy (intercept az/aws auth URL) ——————————————————————————

class BrowserProxy:
    """Local HTTP server that intercepts the $BROWSER call from az/aws."""

    def __init__(self):
        self.url_event = threading.Event()
        self.auth_url: Optional[str] = None
        self._notified = False
        self._lock = threading.Lock()
        self.port = self._free_port()
        self.shim_dir: Optional[Path] = None
        self.shim_path: Optional[Path] = None
        self._server: Optional[http.server.HTTPServer] = None
        self._thread: Optional[threading.Thread] = None

    @staticmethod
    def _free_port() -> int:
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def _handle(self, url: str):
        with self._lock:
            if not self._notified and url:
                self._notified = True
                self.auth_url = url
                self.url_event.set()

    def start(self):
        proxy = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                params = urllib.parse.parse_qs(parsed.query)
                url = params.get("url", [""])[0]
                proxy._handle(url)
                self.send_response(204)
                self.end_headers()

            def log_message(self, *_):
                pass

        self._server = http.server.HTTPServer(("127.0.0.1", self.port), Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

        # Write shim script
        shim_id = str(uuid.uuid4())[:8]
        self.shim_dir = Path.home() / "Library" / "Application Support" / "keystone" / f"shim-{shim_id}"
        self.shim_dir.mkdir(parents=True, exist_ok=True)

        self.shim_path = self.shim_dir / "browser"
        self.shim_path.write_text(
            f"#!/usr/bin/env python3\n"
            f"import sys, urllib.parse, urllib.request\n"
            f"url = sys.argv[1] if len(sys.argv) > 1 else ''\n"
            f"if url:\n"
            f"    try:\n"
            f"        encoded = urllib.parse.quote(url, safe='')\n"
            f"        urllib.request.urlopen(f'http://127.0.0.1:{self.port}/open?url={{encoded}}')\n"
            f"    except Exception:\n"
            f"        pass\n"
        )
        self.shim_path.chmod(0o700)

        # Fake 'open' to swallow browser:// calls az makes internally
        fake_open = self.shim_dir / "open"
        fake_open.write_text(
            "#!/bin/sh\n"
            "for arg; do\n"
            "  case \"$arg\" in\n"
            "    browser://*|ms-appx*|*go.microsoft.com/fwlink*) exit 0 ;;\n"
            "  esac\n"
            "done\n"
            "exec /usr/bin/open \"$@\"\n"
        )
        fake_open.chmod(0o700)

        # Register cleanup
        atexit.register(self.stop)

    def wait_for_url(self, timeout: float = 30.0) -> Optional[str]:
        self.url_event.wait(timeout)
        return self.auth_url

    def stop(self):
        if self._server:
            self._server.shutdown()
            self._server = None
        if self.shim_dir and self.shim_dir.exists():
            shutil.rmtree(self.shim_dir, ignore_errors=True)
            self.shim_dir = None


# — Edge app-mode launcher ————————————————————————————————————————————

def _launch_edge_app(url: str) -> Optional[subprocess.Popen]:
    if not Path(EDGE).exists():
        console.print("[yellow]Edge not found, opening default browser[/]")
        subprocess.Popen(["open", url])
        return None
    proc = subprocess.Popen([
        EDGE,
        f"--app={url}",
        "--window-size=520,640",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc


# — Azure login ———————————————————————————————————————————————————————

def login_azure(t: Tenant, reason: str = "", status_cb=None) -> bool:
    status = _make_status_cb(status_cb)

    bp = BrowserProxy()
    bp.start()

    env = _az_env(t)
    env["BROWSER"] = str(bp.shim_path)
    env["PATH"] = str(bp.shim_dir) + ":" + env.get("PATH", "")

    args = ["az", "login"]
    if t.tenant_id:
        args += ["--tenant", t.tenant_id]
    args += ["--allow-no-subscriptions", "--only-show-errors"]
    if t.pim and t.pim.claims_b64:
        args += ["--claims-challenge", t.pim.claims_b64]
    else:
        args += ["--output", "none"]

    proc = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    with Live(Spinner("dots", text=" waiting for auth URL…"), console=console,
              refresh_per_second=12, transient=True):
        auth_url = bp.wait_for_url(30)

    if not auth_url:
        proc.kill()
        bp.stop()
        status("timed out waiting for auth URL")
        return False

    status("browser opened — complete MFA…")
    edge_proc = _launch_edge_app(auth_url)

    with Live(Spinner("dots", text=" authenticating…"), console=console,
              refresh_per_second=12, transient=True):
        proc.wait()

    if edge_proc:
        try:
            edge_proc.terminate()
        except Exception:
            pass

    bp.stop()

    secs = _token_secs_left_azure(t)
    if secs > 0:
        status(f"token valid for {fmt_duration(secs)}")
        return True
    else:
        status("login completed but token not detected")
        return True


# — PIM activation ————————————————————————————————————————————————————

def activate_pim(t: Tenant, reason: str, status_cb=None) -> bool:
    status = _make_status_cb(status_cb)

    if not t.pim:
        return True

    pim = t.pim
    env = _az_env(t)

    # Get signed-in user OID
    status("getting user OID…")
    r = subprocess.run(
        ["az", "ad", "signed-in-user", "show", "--query", "id", "-o", "tsv"],
        env=env, capture_output=True, text=True
    )
    if r.returncode != 0:
        status(f"could not get user OID: {r.stderr.strip()}")
        return False
    user_oid = r.stdout.strip()

    # Resolve role GUID if not provided
    role_guid = pim.role_guid
    if not role_guid and pim.subscription:
        status(f"looking up role '{pim.role}'…")
        r2 = subprocess.run([
            "az", "role", "definition", "list",
            "--name", pim.role,
            "--query", "[0].name", "-o", "tsv"
        ], env=env, capture_output=True, text=True)
        if r2.returncode == 0:
            role_guid = r2.stdout.strip()

    if not role_guid:
        status(f"could not resolve role GUID for '{pim.role}'")
        return False

    # Create PIM activation request
    status(f"activating {pim.role}…")
    scope = f"/subscriptions/{pim.subscription}" if pim.subscription else "/"
    request_id = str(uuid.uuid4())
    body = {
        "properties": {
            "principalId": user_oid,
            "roleDefinitionId": f"{scope}/providers/Microsoft.Authorization/roleDefinitions/{role_guid}",
            "requestType": "SelfActivate",
            "justification": reason or pim.reason or "Keystone activation",
            "scheduleInfo": {
                "expiration": {
                    "type": "AfterDuration",
                    "duration": pim.duration or "PT4H"
                }
            }
        }
    }

    body_json = json.dumps(body)
    url = (f"https://management.azure.com{scope}/providers/"
           f"Microsoft.Authorization/roleAssignmentScheduleRequests/{request_id}"
           f"?api-version=2020-10-01")

    r3 = subprocess.run([
        "az", "rest", "--method", "PUT", "--url", url,
        "--body", body_json, "--only-show-errors", "--output", "none"
    ], env=env, capture_output=True, text=True)

    if r3.returncode != 0:
        err = r3.stderr.strip()
        if "RoleAssignmentExists" in err or "already been activated" in err.lower():
            status("PIM already active")
            return True
        status(f"PIM failed: {err[:120]}")
        return False

    status(f"PIM activated ({pim.role})")

    if pim.subscription:
        subprocess.run([
            "az", "account", "set", "--subscription", pim.subscription,
            "--only-show-errors"
        ], env=env, capture_output=True)

    # Brief wait for activation to propagate
    with Live(Spinner("dots", text=" waiting for PIM propagation…"), console=console,
              refresh_per_second=12, transient=True):
        time.sleep(10)

    return True


# — AWS SSO login —————————————————————————————————————————————————————

def login_aws_sso(t: Tenant, status_cb=None) -> bool:
    status = _make_status_cb(status_cb)

    bp = BrowserProxy()
    bp.start()

    env = os.environ.copy()
    env["BROWSER"] = str(bp.shim_path)
    env["PATH"] = str(bp.shim_dir) + ":" + env.get("PATH", "")

    args = ["aws", "sso", "login"]
    if t.profile:
        args += ["--profile", t.profile]

    proc = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    with Live(Spinner("dots", text=" waiting for auth URL…"), console=console,
              refresh_per_second=12, transient=True):
        auth_url = bp.wait_for_url(30)

    if not auth_url:
        proc.kill()
        bp.stop()
        status("timed out waiting for auth URL")
        return False

    status("browser opened — complete auth…")
    edge_proc = _launch_edge_app(auth_url)

    with Live(Spinner("dots", text=" authenticating…"), console=console,
              refresh_per_second=12, transient=True):
        proc.wait()

    if edge_proc:
        try:
            edge_proc.terminate()
        except Exception:
            pass

    bp.stop()
    return True


# — Login orchestration ———————————————————————————————————————————————

def login_one(t: Tenant, reason: str = "", status_cb=None) -> str:
    """Returns final state: 'done', 'fresh', 'error'"""
    status = _make_status_cb(status_cb)

    secs = token_secs_left(t)
    if secs > 1800:
        return "fresh"

    if t.provider == "azure":
        ok = login_azure(t, reason, status_cb)
        if not ok:
            return "error"
        # Activate all PIM roles (pims list takes precedence; fall back to single pim)
        all_pims = t.pims if t.pims else ([t.pim] if t.pim else [])
        for pim_cfg in all_pims:
            t_copy = Tenant(**{**t.__dict__, 'pim': pim_cfg, 'pims': []})
            pim_ok = activate_pim(t_copy, reason, status_cb)
            if not pim_ok:
                return "error"
        return "done"
    elif t.provider == "aws-sso":
        ok = login_aws_sso(t, status_cb)
        return "done" if ok else "error"
    return "error"


# — Notifications —————————————————————————————————————————————————————

def _notify(title: str, msg: str):
    """macOS notification — no special permissions needed."""
    try:
        subprocess.run([
            "osascript", "-e",
            f'display notification "{msg}" with title "{title}"'
        ], capture_output=True, timeout=3)
    except Exception:
        pass


# — Batch login ———————————————————————————————————————————————————————

def login_all(tenants: list[Tenant], reason: str = ""):
    sso_done: set[str] = set()
    errors = []
    for t in tenants:
        if not t.enabled:
            continue

        console.print(f"\n  [bold]{t.name}[/] [dim]({t.provider})[/]")

        if t.provider == "aws-sso" and t.sso_start_url:
            if t.sso_start_url in sso_done:
                secs = token_secs_left(t)
                console.print(f"    [green]✔[/] SSO session reused — {fmt_duration(secs)} remaining")
                continue
            sso_done.add(t.sso_start_url)

        def cb(msg, _t=t):
            console.print(f"    [dim]→ {msg}[/]")

        result = login_one(t, reason, cb)
        if result == "fresh":
            secs = token_secs_left(t)
            console.print(f"    [green]✔[/] fresh — {fmt_duration(secs)} remaining")
        elif result == "done":
            console.print(f"    [green]✔[/] always smooth")
        else:
            console.print(f"    [red]✗[/] failed")
            errors.append(t.name)

    if errors:
        _notify("Keystone", f"Login failed: {', '.join(errors)}")
    else:
        _notify("Keystone", "All tokens refreshed ✔")


# — TUI helpers ———————————————————————————————————————————————————————

def _prompt_with_timeout(prompt: str, timeout: int = 60) -> str:
    """Display prompt and return input. Returns '' after timeout (triggers refresh).
    Reads character-by-character so Esc is detected immediately."""
    import select
    import tty
    import termios
    console.print(prompt, end="", highlight=False)
    sys.stdout.flush()

    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        buf = []
        while True:
            ready, _, _ = select.select([sys.stdin], [], [], timeout)
            if not ready:
                console.print()
                return ""
            ch = sys.stdin.read(1)
            # Esc
            if ch == "\x1b":
                console.print()
                return "\x1b"
            # Enter
            if ch in ("\r", "\n"):
                console.print()
                return "".join(buf).strip().lower()
            # Backspace
            if ch in ("\x7f", "\x08"):
                if buf:
                    buf.pop()
                    sys.stdout.write("\b \b")
                    sys.stdout.flush()
                continue
            # Ctrl-C
            if ch == "\x03":
                console.print()
                raise KeyboardInterrupt
            buf.append(ch)
            sys.stdout.write(ch)
            sys.stdout.flush()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)


# — TUI dashboard —————————————————————————————————————————————————————

def _ttl_color(secs: int) -> str:
    if secs > 3600:    return "green"
    if secs > 1800:    return "yellow"
    if secs > 0:       return "red"
    return "bright_black"


def _make_table(tenants: list[Tenant], states: dict) -> Table:
    from rich.box import SIMPLE_HEAVY
    table = Table(show_header=True, header_style="bold", box=SIMPLE_HEAVY, padding=(0, 1),
                  show_edge=False)
    table.add_column("Tenant",     style="bold", no_wrap=True, min_width=22)
    table.add_column("Provider",   no_wrap=True, width=9)
    table.add_column("TTL",        no_wrap=True, width=8)
    table.add_column("Status",     no_wrap=True)

    for t in tenants:
        if not t.enabled:
            continue
        state_info = states.get(t.name, {})
        state = state_info.get("state", "idle")
        msg   = state_info.get("msg", "")
        secs  = token_secs_left(t)
        tcolor = _ttl_color(secs)
        ttl   = f"[{tcolor}]{fmt_duration(secs)}[/]" if secs > 0 else "[bright_black]-[/]"

        if state == "fresh":
            status_str = f"[green]● fresh[/]"
        elif state == "done":
            status_str = f"[green]✔ done[/]"
        elif state == "error":
            status_str = f"[red]✗ {msg}[/]"
        elif state in ("logging_in", "pim", "checking"):
            status_str = f"[yellow]◌ {msg}[/]"
        elif secs > 0:
            status_str = f"[{tcolor}]expiring[/]"
        else:
            status_str = "[bright_black]expired[/]"

        # Shorten provider label
        provider = {"azure": "az", "aws-sso": "aws"}.get(t.provider, t.provider)

        table.add_row(t.name, provider, ttl, status_str)
    return table


def tui(tenants: list[Tenant], reason: str = ""):
    """Interactive TUI: show dashboard, prompt for action."""
    enabled = [t for t in tenants if t.enabled]
    sso_done: set[str] = set()
    last_refresh: Optional[str] = None

    while True:
        console.clear()
        console.rule("[bold cyan]KEYSTONE[/] [dim]— multi-cloud auth[/]")
        console.print()

        states = {}
        for t in enabled:
            secs = token_secs_left(t)
            if secs > 1800:
                states[t.name] = {"state": "fresh"}
            elif secs > 0:
                states[t.name] = {"state": "idle"}
            else:
                states[t.name] = {"state": "idle"}

        all_fresh = all(token_secs_left(t) > 1800 for t in enabled)
        footer = Text()
        if all_fresh:
            footer.append("always smooth 😎 ", style="green bold")
        if last_refresh:
            footer.append(f"refreshed {last_refresh}", style="dim")

        console.print(Panel(
            _make_table(enabled, states),
            subtitle=footer,
            border_style="dim",
            padding=(0, 1),
            width=min(80, console.width - 2),
        ))
        console.print("[dim]  a[/] login all    [dim]<name>[/] login one    [dim]c[/] refresh    [dim]q/esc[/] quit")
        console.print()

        try:
            cmd = _prompt_with_timeout("  [bold]>[/] ", timeout=60)
        except (KeyboardInterrupt, EOFError):
            console.print()
            break

        # Quit: q, quit, or Esc (shows as \x1b)
        if cmd in ("q", "quit", "\x1b"):
            break

        # Refresh dashboard (empty input from timeout, or explicit 'c')
        elif cmd in ("", "c"):
            last_refresh = time.strftime("%H:%M:%S")
            continue

        # Login all
        elif cmd == "a":
            # Confirm if all tokens are already fresh
            if all_fresh:
                try:
                    confirm = Prompt.ask("  [yellow]All tokens fresh — login anyway?[/] [dim](y/N)[/]", default="n").strip().lower()
                except (KeyboardInterrupt, EOFError):
                    console.print()
                    continue
                if confirm != "y":
                    continue
            console.print()
            sso_done.clear()
            login_all(enabled, reason)
            last_refresh = time.strftime("%H:%M:%S")
            # Auto-refresh dashboard after brief pause
            time.sleep(1.5)
            continue

        # Login single tenant
        else:
            match = next((t for t in enabled if t.name.lower() == cmd), None)
            if not match:
                # Fuzzy prefix match
                candidates = [t for t in enabled if t.name.lower().startswith(cmd)]
                if len(candidates) == 1:
                    match = candidates[0]
                else:
                    console.print(f"  [red]Unknown:[/] {cmd}" + (f" — did you mean {', '.join(t.name for t in candidates)}?" if candidates else ""))
                    time.sleep(1.5)
                    continue

            if match.provider == "aws-sso" and match.sso_start_url in sso_done:
                console.print(f"  [green]SSO session already active for {match.name}[/]")
                time.sleep(1)
                continue
            if match.provider == "aws-sso":
                sso_done.add(match.sso_start_url)

            console.print()
            console.print(f"  [bold]{match.name}[/]")

            def cb(msg):
                console.print(f"    [dim]→ {msg}[/]")

            result = login_one(match, reason, cb)
            if result == "fresh":
                console.print(f"    [green]✔[/] already fresh")
            elif result == "done":
                console.print(f"    [green]✔[/] always smooth")
            else:
                console.print(f"    [red]✗[/] failed")

            last_refresh = time.strftime("%H:%M:%S")
            time.sleep(1.5)
            continue


# — Silent refresh ————————————————————————————————————————————————————

def refresh_all(tenants: list[Tenant]):
    """Silently refresh tokens without opening a browser.
    Azure: az account get-access-token (uses cached refresh token).
    AWS SSO: skipped if session cache is still valid.
    Exits non-zero if any refresh fails."""
    sso_done: set[str] = set()
    errors = []
    for t in tenants:
        if t.provider == "azure":
            env = _az_env(t)
            args = ["az", "account", "get-access-token", "--only-show-errors", "--output", "none"]
            if t.tenant_id:
                args += ["--tenant", t.tenant_id]
            r = subprocess.run(args, env=env, capture_output=True)
            secs = token_secs_left(t)
            color = "green" if r.returncode == 0 else "red"
            mark = "✔" if r.returncode == 0 else "✗"
            console.print(f"  [{color}]{mark}[/] {t.name:24} {fmt_duration(secs)}")
            if r.returncode != 0:
                errors.append(t.name)

        elif t.provider == "aws-sso":
            if t.sso_start_url in sso_done:
                secs = token_secs_left(t)
                console.print(f"  [dim]-[/] {t.name:24} {fmt_duration(secs)} [dim](reused)[/]")
                continue
            sso_done.add(t.sso_start_url)
            secs = token_secs_left(t)
            if secs > 0:
                console.print(f"  [green]✔[/] {t.name:24} {fmt_duration(secs)}")
            else:
                console.print(f"  [red]✗[/] {t.name:24} expired — run [bold]ks login[/]")
                errors.append(t.name)

    if errors:
        _notify("Keystone", f"Refresh failed: {', '.join(errors)}")
        sys.exit(1)
    else:
        _notify("Keystone", "All tokens refreshed ✔")


# — Entry point ——————————————————————————————————————————————————————

def main():
    parser = argparse.ArgumentParser(prog="ks", description="Keystone — multi-cloud auth")
    parser.add_argument("command", nargs="?", default="tui",
                        help="tui (default), login, check, refresh")
    parser.add_argument("tenant", nargs="?", default=None,
                        help="Tenant name for single login")
    parser.add_argument("--reason", "-r", default="",
                        help="PIM justification reason")
    args = parser.parse_args()

    cfg, tenants = load_config()
    apply_env(cfg)
    enabled = [t for t in tenants if t.enabled]

    if args.command == "check":
        for t in enabled:
            secs = token_secs_left(t)
            color = "green" if secs > 1800 else "yellow" if secs > 0 else "red"
            provider = {"azure": "az", "aws-sso": "aws"}.get(t.provider, t.provider)
            console.print(f"  [{color}]{t.name:20}[/] {provider:5} {fmt_duration(secs)}")

    elif args.command == "refresh":
        refresh_all(enabled)

    elif args.command == "login":
        if args.tenant:
            match = next((t for t in enabled if t.name.lower() == args.tenant.lower()), None)
            if not match:
                console.print(f"[red]Tenant not found:[/] {args.tenant}")
                sys.exit(1)
            console.print(f"[bold]{match.name}[/]")
            result = login_one(match, args.reason)
            console.print("[green]✔ done[/]" if result != "error" else "[red]✗ failed[/]")
        else:
            login_all(enabled, args.reason)

    else:  # tui
        tui(enabled, args.reason)


if __name__ == "__main__":
    main()
