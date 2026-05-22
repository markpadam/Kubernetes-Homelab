#!/usr/bin/env python3
"""
AKS Lab — interactive menu.

Invoked by ./aks-lab when no subcommand is given. Renders a numbered
action list with a live status header, lets the user pick an action,
shells out to the matching ./aks-lab <subcommand>, then loops back to
the menu when the action finishes.

Usage: python3 scripts/menu.py <repo-root>
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
AKS_LAB = REPO_ROOT / "aks-lab"
PROFILE = os.environ.get("LAB_PROFILE", "aks-lab")

try:
    from rich.console import Console
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
    from rich.prompt import Prompt
    from rich import box
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "rich"])
    from rich.console import Console
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
    from rich.prompt import Prompt
    from rich import box

console = Console()


def cluster_state() -> tuple[str, str]:
    """Return (state_label, style) for the status header."""
    try:
        result = subprocess.run(
            ["minikube", "status", "-p", PROFILE],
            capture_output=True, text=True, timeout=5,
        )
        out = result.stdout
        if "host: Running" in out and "apiserver: Running" in out:
            return "running", "green"
        if "host: Stopped" in out or "host: " not in out:
            return "stopped", "yellow"
        return "degraded", "yellow"
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return "unknown", "red"


def enabled_count() -> str:
    """Read .lab-state.json and return 'N enabled' or '—'."""
    state_file = REPO_ROOT / ".lab-state.json"
    if not state_file.exists():
        return "—"
    try:
        data = json.loads(state_file.read_text())
        n = len(data.get("enabled", []))
        return f"{n} enabled"
    except Exception:
        return "—"


def load_components() -> tuple[list[dict], set[str]]:
    """Return (components, enabled_ids) from lab-components.json and .lab-state.json."""
    registry = REPO_ROOT / "lab-components.json"
    components = json.loads(registry.read_text())["components"]
    state_file = REPO_ROOT / ".lab-state.json"
    enabled: set[str] = set()
    if state_file.exists():
        try:
            enabled = set(json.loads(state_file.read_text()).get("enabled", []))
        except Exception:
            pass
    return components, enabled


# (label, subcommand-args-or-None, dim-when-state, description)
# dim-when-state: "running" → only when cluster running, "stopped" → only when stopped, None → always
# argv=None means the action is handled inline (features sub-menu)
ACTIONS = [
    ("Setup",      ["setup"],   "stopped", "Build and start the lab (~15 min)"),
    ("Resume",     ["resume"],  "stopped", "Resume after pause or Mac restart"),
    ("Pause",      ["pause"],   "running", "minikube stop — keeps all state"),
    ("Verify",     ["verify"],  "running", "Post-setup health check"),
    ("Test All",   ["test-all", "--no-setup"], "running", "Sequential full deploy test"),
    ("Features",   None,        "running", "Enable / disable components"),
    ("Refresh",    ["refresh"], "running", "Re-apply manifests on running cluster"),
    ("Resize",     ["resize"],  "running", "Shrink node memory after cluster settles"),
    ("Dashboard",  ["dashboard"], "running", "Open the web dashboard"),
    ("Teardown",   ["teardown"], None,      "Full wipe — cluster, VMs, hosts"),
]


def render_menu(state: str, state_style: str) -> None:
    """Clear screen and draw the status header + action list."""
    console.clear()
    header = Text()
    header.append("  cluster: ", style="dim")
    header.append(state, style=f"bold {state_style}")
    header.append(f"   ·   profile: {PROFILE}", style="dim")
    header.append(f"   ·   components: {enabled_count()}", style="dim")
    console.print(Panel(header, title="[bold cyan]  AKS Lab  [/]",
                        box=box.ROUNDED, border_style="cyan", padding=(0, 2)))

    table = Table(show_header=False, box=None, padding=(0, 2))
    table.add_column(width=4)
    table.add_column(width=14)
    table.add_column()
    for i, (label, _argv, gate, desc) in enumerate(ACTIONS, start=1):
        dim = (gate == "running" and state != "running") or (gate == "stopped" and state == "running")
        label_style = "dim" if dim else "bold"
        desc_style  = "dim" if dim else "white"
        num_style   = "dim cyan" if dim else "cyan bold"
        table.add_row(
            Text(f" {i}.", style=num_style),
            Text(label, style=label_style),
            Text(desc, style=desc_style),
        )
    table.add_row(Text(" 0.", style="cyan bold"),
                  Text("Exit", style="bold"),
                  Text("Quit the menu", style="white"))
    console.print(table)
    console.print()


def run_action(argv: list[str]) -> None:
    """Shell out to ./aks-lab <argv> in the foreground and wait."""
    console.print(f"\n[dim]→ running ./aks-lab {' '.join(argv)}[/]\n")
    try:
        subprocess.run([str(AKS_LAB), *argv], cwd=str(REPO_ROOT))
    except KeyboardInterrupt:
        console.print("\n[yellow]  (interrupted)[/]")
    console.print("\n[dim]press Enter to return to the menu...[/]", end="")
    try:
        input()
    except EOFError:
        pass


def features_menu() -> None:
    """Interactive component enable/disable sub-menu."""
    while True:
        components, enabled = load_components()
        state, state_style = cluster_state()

        console.clear()
        header = Text()
        header.append("  cluster: ", style="dim")
        header.append(state, style=f"bold {state_style}")
        n_on = len(enabled)
        n_total = len(components)
        header.append(f"   ·   {n_on}/{n_total} components enabled", style="dim")
        console.print(Panel(
            header,
            title="[bold cyan]  Features  [/]",
            box=box.ROUNDED, border_style="cyan", padding=(0, 2),
        ))

        table = Table(show_header=False, box=None, padding=(0, 1))
        table.add_column(width=4,  no_wrap=True)   # number
        table.add_column(width=22, no_wrap=True)   # id
        table.add_column(width=30, no_wrap=True)   # name
        table.add_column(width=12, no_wrap=True)   # state badge
        table.add_column()                         # deps / desc

        items: list[dict] = []
        cur_group: str | None = None

        for comp in components:
            grp = comp.get("group", "")
            if grp != cur_group:
                if cur_group is not None:
                    table.add_row("", "", "", "", "")
                table.add_row(
                    "",
                    f"[bold cyan]{grp.upper()}[/]",
                    "", "", "",
                )
                cur_group = grp

            n = len(items) + 1
            items.append(comp)
            is_on = comp["id"] in enabled
            deps = comp.get("depends", [])
            dep_note = f"[dim]← {', '.join(deps)}[/]" if deps else ""

            if is_on:
                table.add_row(
                    f"[cyan bold] {n}.[/]",
                    f"[bold]{comp['id']}[/]",
                    comp["name"],
                    "[green]● enabled[/]",
                    dep_note,
                )
            else:
                table.add_row(
                    f"[dim cyan] {n}.[/]",
                    f"[dim]{comp['id']}[/]",
                    f"[dim]{comp['name']}[/]",
                    "[dim]○ disabled[/]",
                    dep_note,
                )

        console.print(table)
        console.print()
        console.print("[dim]  Enter a number to enable/disable · 0 or Enter to go back[/]")
        console.print()

        try:
            choice = Prompt.ask("[bold cyan]feature[/]", default="0").strip()
        except (KeyboardInterrupt, EOFError):
            return

        if choice in ("0", "", "q", "back", "b"):
            return

        if not choice.isdigit():
            console.print(f"[red]  unknown: {choice!r}[/]")
            time.sleep(1)
            continue

        idx = int(choice) - 1
        if not (0 <= idx < len(items)):
            console.print(f"[red]  out of range: {choice}[/]")
            time.sleep(1)
            continue

        comp = items[idx]
        comp_id = comp["id"]
        is_on = comp_id in enabled
        action = "disable" if is_on else "enable"

        console.print(f"\n[dim]→ ./aks-lab feature {action} {comp_id}[/]\n")
        try:
            subprocess.run([str(AKS_LAB), "feature", action, comp_id], cwd=str(REPO_ROOT))
        except KeyboardInterrupt:
            console.print("\n[yellow]  (interrupted)[/]")

        console.print("\n[dim]press Enter to continue...[/]", end="")
        try:
            input()
        except EOFError:
            pass


def main() -> None:
    while True:
        state, state_style = cluster_state()
        render_menu(state, state_style)
        choice = Prompt.ask("[bold cyan]select[/]", default="0").strip()
        if choice in ("0", "q", "quit", "exit"):
            console.print("[dim]bye.[/]")
            return
        if not choice.isdigit():
            console.print(f"[red]  unknown choice: {choice}[/]")
            continue
        idx = int(choice) - 1
        if 0 <= idx < len(ACTIONS):
            label, argv, gate, _ = ACTIONS[idx]
            blocked = (gate == "running" and state != "running") or \
                      (gate == "stopped" and state == "running")
            if blocked:
                reason = "cluster must be running" if gate == "running" else "cluster must be stopped"
                console.print(f"[yellow]  {label} is not available right now ({reason})[/]")
                console.print("[dim]press Enter to continue...[/]", end="")
                try:
                    input()
                except EOFError:
                    pass
            elif label == "Features":
                features_menu()
            else:
                run_action(argv)
        else:
            console.print(f"[red]  out of range: {choice}[/]")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        console.print("\n[dim]bye.[/]")
