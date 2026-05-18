#!/usr/bin/env python3
"""
AKS Homelab setup TUI — reads JSON events from a FIFO and renders a live dashboard.
Usage: python3 scripts/tui.py <fifo-path>
"""
import sys
import json
import time
import threading
from datetime import datetime

FIFO_PATH = sys.argv[1] if len(sys.argv) > 1 else None

try:
    import rich  # noqa: F401
except ImportError:
    import subprocess
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "--quiet", "rich"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

from rich.console import Console
from rich.layout import Layout
from rich.panel import Panel
from rich.text import Text
from rich.live import Live
from rich import box

ICON = {
    "pending": "○",
    "running": "►",
    "done":    "✓",
    "warn":    "~",
    "fail":    "✗",
}
STYLE = {
    "pending": "dim",
    "running": "cyan bold",
    "done":    "green bold",
    "warn":    "yellow bold",
    "fail":    "red bold",
}


class State:
    def __init__(self):
        self.steps: list[dict] = []
        self.logs: list[tuple] = []         # (ts, level, msg)
        self.health: list[tuple] = []
        self.ready_lines: list[tuple] = []  # (style, text) for Lab Ready page
        self.start = time.monotonic()
        self.phase = "Starting..."
        self.finished = False
        self.final_pass = 0
        self.final_fail = 0
        self._lock = threading.Lock()

    def handle(self, raw: str) -> None:
        try:
            evt = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            return
        with self._lock:
            e = evt.get("event", "")
            if e == "step_start":
                for s in self.steps:
                    if s["status"] == "running":
                        s["status"] = "done"
                self.steps.append({
                    "id": evt.get("id", 0),
                    "label": evt.get("label", ""),
                    "status": "running",
                    "elapsed": "",
                })
                self.phase = evt.get("label", "")
            elif e == "step_done":
                sid = evt.get("id", -1)
                for s in self.steps:
                    if s["id"] == sid and s["status"] == "running":
                        s["status"] = "done"
                        s["elapsed"] = evt.get("elapsed", "")
            elif e in ("step_warn", "step_fail"):
                sid = evt.get("id", -1)
                status = "warn" if e == "step_warn" else "fail"
                for s in self.steps:
                    if s["id"] == sid:
                        s["status"] = status
                        s["elapsed"] = evt.get("elapsed", "")
            elif e in ("log", "success", "warn", "error"):
                ts = datetime.now().strftime("%H:%M:%S")
                self.logs.append((ts, e, evt.get("msg", "")))
                if len(self.logs) > 500:
                    self.logs = self.logs[-500:]
            elif e == "health_result":
                self.health.append((
                    evt.get("label", ""),
                    evt.get("status", ""),
                    evt.get("detail", ""),
                ))
            elif e == "info":
                self.ready_lines.append((
                    evt.get("style", ""),
                    evt.get("msg", ""),
                ))
            elif e == "done":
                for s in self.steps:
                    if s["status"] == "running":
                        s["status"] = "done"
                self.phase = "Complete"
                self.finished = True
                self.final_pass = evt.get("pass", 0)
                self.final_fail = evt.get("fail", 0)

    def elapsed(self) -> str:
        secs = int(time.monotonic() - self.start)
        h = secs // 3600
        m = (secs % 3600) // 60
        s = secs % 60
        return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"

    def render(self, log_height: int = 20) -> Layout:
        with self._lock:
            steps = list(self.steps)
            logs = list(self.logs[-log_height:])
            health = list(self.health)
            elapsed = self.elapsed()
            phase = self.phase
            finished = self.finished
            f_pass = self.final_pass
            f_fail = self.final_fail

        # ── Steps panel ──────────────────────────────────────────────────
        steps_text = Text()
        for s in steps:
            status = s["status"]
            icon = ICON[status]
            icon_style = STYLE[status]
            label_style = (
                "bold" if status == "running"
                else "dim" if status == "pending"
                else "default"
            )
            steps_text.append(f"  {icon}  ", style=icon_style)
            steps_text.append(s["label"], style=label_style)
            if s.get("elapsed") and status in ("done", "warn", "fail"):
                steps_text.append(f"  ({s['elapsed']})", style="dim")
            steps_text.append("\n")

        # ── Log panel ─────────────────────────────────────────────────────
        log_text = Text()
        level_style = {
            "log":     "white",
            "success": "green",
            "warn":    "yellow",
            "error":   "red bold",
        }
        level_prefix = {
            "log":     "    ",
            "success": " ✓  ",
            "warn":    "[!] ",
            "error":   "[✗] ",
        }
        for ts, level, msg in logs:
            pfx = level_prefix.get(level, "    ")
            sty = level_style.get(level, "white")
            log_text.append(f"[{ts}] {pfx}", style="dim")
            log_text.append(f"{msg}\n", style=sty)

        if health:
            log_text.append(
                "\n  ─── Health Check ───────────────────────────────────\n",
                style="bold dim",
            )
            hstyle = {"ok": "green bold", "warn": "yellow bold", "fail": "red bold"}
            hicon  = {"ok": "✓", "warn": "~", "fail": "✗"}
            for label, status, detail in health:
                ic = hicon.get(status, "?")
                hs = hstyle.get(status, "white")
                log_text.append(f"  {ic}  ", style=hs)
                log_text.append(f"{label:<22}", style=hs)
                log_text.append(f" {detail}\n", style=hs)

        # ── Status bar ───────────────────────────────────────────────────
        if finished:
            if f_fail == 0:
                bar = Text(
                    f"  ✓  Complete · {elapsed} · {f_pass} components healthy",
                    style="green bold",
                )
            else:
                total = f_pass + f_fail
                bar = Text(
                    f"  ~  Complete · {elapsed} · {f_pass}/{total} healthy,"
                    f" {f_fail} need attention",
                    style="yellow bold",
                )
        else:
            bar = Text(f"  ►  {phase}  ·  Elapsed: {elapsed}", style="cyan")

        # ── Assemble layout ──────────────────────────────────────────────
        layout = Layout()
        layout.split_column(
            Layout(name="header", size=3),
            Layout(name="body"),
            Layout(name="footer", size=3),
        )
        layout["header"].update(Panel(
            Text("  AKS Homelab Setup", style="bold cyan"),
            box=box.ROUNDED,
            border_style="blue",
        ))
        layout["body"].split_row(
            Layout(
                Panel(
                    steps_text,
                    title="[bold]Steps[/bold]",
                    box=box.ROUNDED,
                    border_style="blue",
                    padding=(0, 1),
                ),
                ratio=1,
                minimum_size=30,
            ),
            Layout(
                Panel(
                    log_text,
                    title="[bold]Log[/bold]",
                    box=box.ROUNDED,
                    border_style="blue",
                    padding=(0, 1),
                ),
                ratio=2,
            ),
        )
        layout["footer"].update(Panel(bar, box=box.ROUNDED, border_style="blue"))
        return layout


def show_ready_page(state: State, console: Console) -> None:
    """Replace the TUI with a full-screen Lab Ready summary; exit on Enter."""
    elapsed = state.elapsed()
    f_pass  = state.final_pass
    f_fail  = state.final_fail
    total   = f_pass + f_fail

    # ── Health summary bar ───────────────────────────────────────────────
    if f_fail == 0:
        health_bar = Text(f"  ✓  {f_pass}/{total} components healthy", style="green bold")
        bar_border = "green"
    else:
        health_bar = Text(
            f"  ~  {f_pass}/{total} components healthy · {f_fail} need attention",
            style="yellow bold",
        )
        bar_border = "yellow"

    # ── Info panel content ───────────────────────────────────────────────
    info_text = Text()
    style_map = {
        "header": "bold cyan",
        "key":    "green",
        "dim":    "dim",
        "":       "white",
    }
    for item_style, line in state.ready_lines:
        sty = style_map.get(item_style, "white")
        info_text.append(line + "\n", style=sty)

    console.clear()
    console.print()
    console.print(Panel(health_bar, box=box.ROUNDED, border_style=bar_border))
    console.print(Panel(
        info_text,
        title=f"[bold green]  Lab Ready  ✓  — Deployed in {elapsed}[/bold green]",
        border_style="green",
        box=box.ROUNDED,
        padding=(0, 2),
    ))
    console.print("\n  [dim]Press Enter to close[/dim]")
    try:
        input()
    except (EOFError, KeyboardInterrupt):
        pass


def reader_thread(fifo_path: str, state: State) -> None:
    try:
        with open(fifo_path, "r") as f:
            for line in f:
                line = line.strip()
                if line:
                    state.handle(line)
    except (OSError, IOError):
        pass
    finally:
        state.finished = True


def main() -> None:
    if not FIFO_PATH:
        print("Usage: tui.py <fifo-path>", file=sys.stderr)
        sys.exit(1)

    if not sys.stdout.isatty():
        try:
            with open(FIFO_PATH, "r") as f:
                for _ in f:
                    pass
        except OSError:
            pass
        return

    state = State()
    console = Console()

    t = threading.Thread(target=reader_thread, args=(FIFO_PATH, state), daemon=True)
    t.start()

    with Live(
        state.render(),
        console=console,
        refresh_per_second=4,
        screen=True,
    ) as live:
        while not state.finished:
            body_height = max(5, console.size.height - 9)
            live.update(state.render(log_height=body_height))
            time.sleep(0.25)
        # One final render so the completion state is visible for a beat
        live.update(state.render(log_height=max(5, console.size.height - 9)))
        time.sleep(0.5)
    # Live exits → terminal restored. Show the interactive Lab Ready page.
    if state.ready_lines:
        show_ready_page(state, console)


if __name__ == "__main__":
    main()
