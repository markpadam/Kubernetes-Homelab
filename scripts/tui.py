#!/usr/bin/env python3
"""
AKS Homelab setup TUI — reads JSON events from a FIFO and renders a live dashboard.
Usage: python3 scripts/tui.py <fifo-path> [log-file]
"""
import re
import sys
import json
import time
import threading
from datetime import datetime

FIFO_PATH   = sys.argv[1] if len(sys.argv) > 1 else None
VERBOSE_LOG = sys.argv[2] if len(sys.argv) > 2 else None

try:
    import rich  # noqa: F401
except ImportError:
    import subprocess
    import importlib
    import site
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "--quiet", "rich"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    importlib.invalidate_caches()
    user_site = site.getusersitepackages()
    if user_site not in sys.path:
        sys.path.insert(0, user_site)

from rich.console import Console
from rich.layout import Layout
from rich.panel import Panel
from rich.text import Text
from rich.live import Live
from rich import box

_ANSI_RE = re.compile(
    r'\x1b\[[0-9;]*[mKHFABCDJGrh]'
    r'|\x1b\[[?][0-9;]*[hl]'
    r'|\x1b[=>]'
)

def strip_ansi(s: str) -> str:
    return _ANSI_RE.sub('', s)

ACTIVITY_RATIO = 3  # Activity : Verbose = 3:2 (≈ 60% : 40%)

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
        self.logs: list[tuple] = []
        self.health: list[tuple] = []
        self.verbose_lines: list[str] = []
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
                    "id":      evt.get("id", 0),
                    "label":   evt.get("label", ""),
                    "status":  "running",
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
            elif e == "done":
                for s in self.steps:
                    if s["status"] == "running":
                        s["status"] = "done"
                self.phase = "Complete"
                self.finished = True
                self.final_pass = evt.get("pass", 0)
                self.final_fail = evt.get("fail", 0)

    def add_verbose(self, line: str) -> None:
        with self._lock:
            self.verbose_lines.append(line)
            if len(self.verbose_lines) > 2000:
                self.verbose_lines = self.verbose_lines[-2000:]

    def elapsed(self) -> str:
        secs = int(time.monotonic() - self.start)
        h = secs // 3600
        m = (secs % 3600) // 60
        s = secs % 60
        return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"

    def render_completion(self) -> Panel:
        """Full-screen completion panel shown for a few seconds at the end."""
        with self._lock:
            f_pass = self.final_pass
            f_fail = self.final_fail
            health = list(self.health)
        elapsed = self.elapsed()
        total   = f_pass + f_fail

        colour  = "green" if f_fail == 0 else "yellow"
        icon    = "✓" if f_fail == 0 else "~"
        title   = "[bold green]  Setup Complete  [/bold green]" if f_fail == 0 else "[bold yellow]  Setup Complete — Warnings  [/bold yellow]"

        if total > 0:
            summary = f"{f_pass}/{total} components healthy"
            if f_fail:
                summary += f"  ·  {f_fail} need attention"
        else:
            summary = "Setup complete"

        text = Text()
        text.append(f"\n  {icon}  {summary}", style=f"bold {colour}")
        text.append(f"  —  {elapsed}\n\n", style="dim")

        hstyle = {"ok": "green bold", "warn": "yellow bold", "fail": "red bold"}
        hicon  = {"ok": "✓", "warn": "~", "fail": "✗"}
        for label, status, detail in health:
            ic = hicon.get(status, "?")
            hs = hstyle.get(status, "white")
            text.append(f"  {ic}  {label:<24}", style=hs)
            text.append(f" {detail}\n", style="dim")

        text.append("\n  Dashboard → http://localhost:9997/\n", style="dim cyan")

        return Panel(text, title=title, box=box.DOUBLE, border_style=colour, padding=(1, 2))

    def render(self, activity_lines: int = 20, verbose_lines: int = 15) -> Layout:
        with self._lock:
            steps    = list(self.steps)
            logs     = list(self.logs[-activity_lines:])
            health   = list(self.health)
            verbose  = list(self.verbose_lines[-verbose_lines:])
            elapsed  = self.elapsed()
            phase    = self.phase
            finished = self.finished
            f_pass   = self.final_pass
            f_fail   = self.final_fail

        # ── Steps panel ──────────────────────────────────────────────────
        steps_text = Text()
        for s in steps:
            status = s["status"]
            steps_text.append(f"  {ICON[status]}  ", style=STYLE[status])
            steps_text.append(
                s["label"],
                style="bold" if status == "running" else "dim" if status == "pending" else "default",
            )
            if s.get("elapsed") and status in ("done", "warn", "fail"):
                steps_text.append(f"  ({s['elapsed']})", style="dim")
            steps_text.append("\n")

        # ── Activity panel ────────────────────────────────────────────────
        activity_text = Text()
        level_style  = {"log": "white", "success": "green", "warn": "yellow", "error": "red bold"}
        level_prefix = {"log": "    ",  "success": " ✓  ",  "warn": "[!] ",   "error": "[✗] "}
        for ts, level, msg in logs:
            activity_text.append(f"[{ts}] {level_prefix.get(level,'    ')}", style="dim")
            activity_text.append(f"{msg}\n", style=level_style.get(level, "white"))

        if health:
            activity_text.append("\n  ─── Health Check ──────────────────────────\n", style="bold dim")
            hstyle = {"ok": "green bold", "warn": "yellow bold", "fail": "red bold"}
            hicon  = {"ok": "✓", "warn": "~", "fail": "✗"}
            for label, status, detail in health:
                ic = hicon.get(status, "?")
                hs = hstyle.get(status, "white")
                activity_text.append(f"  {ic}  ", style=hs)
                activity_text.append(f"{label:<22}", style=hs)
                activity_text.append(f" {detail}\n", style=hs)

        # ── Verbose panel ─────────────────────────────────────────────────
        verbose_text = Text()
        for line in verbose:
            verbose_text.append(line[:200] + "\n", style="dim")

        # ── Status bar ───────────────────────────────────────────────────
        if finished:
            if f_fail == 0:
                bar = Text(f"  ✓  Complete · {elapsed} · {f_pass} components healthy", style="green bold")
            else:
                total = f_pass + f_fail
                bar = Text(
                    f"  ~  Complete · {elapsed} · {f_pass}/{total} healthy, {f_fail} need attention",
                    style="yellow bold",
                )
        else:
            bar = Text(f"  ►  {phase}  ·  Elapsed: {elapsed}", style="cyan")

        # ── Layout ───────────────────────────────────────────────────────
        layout = Layout()
        layout.split_column(
            Layout(name="header", size=3),
            Layout(name="body"),
            Layout(name="footer", size=3),
        )
        layout["header"].update(Panel(Text("  AKS Homelab Setup", style="bold cyan"), box=box.ROUNDED, border_style="blue"))
        layout["body"].split_row(
            Layout(name="left",  ratio=1, minimum_size=30),
            Layout(name="right", ratio=2),
        )
        layout["left"].update(Panel(steps_text, title="[bold]Steps[/bold]", box=box.ROUNDED, border_style="blue", padding=(0, 1)))
        layout["right"].split_column(
            Layout(name="activity", ratio=ACTIVITY_RATIO),
            Layout(name="verbose",  ratio=2),
        )
        layout["activity"].update(Panel(activity_text, title="[bold]Activity[/bold]",       box=box.ROUNDED, border_style="blue",     padding=(0, 1)))
        layout["verbose"].update( Panel(verbose_text,  title="[bold]Verbose Output[/bold]", box=box.ROUNDED, border_style="dim blue", padding=(0, 1)))
        layout["footer"].update(Panel(bar, box=box.ROUNDED, border_style="blue"))
        return layout


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


def verbose_reader_thread(log_path: str, state: State) -> None:
    try:
        with open(log_path, "r", errors="replace") as f:
            while True:
                line = f.readline()
                if line:
                    clean = strip_ansi(line).rstrip()
                    if clean:
                        state.add_verbose(clean)
                else:
                    if state.finished:
                        break
                    time.sleep(0.1)
    except (OSError, IOError):
        pass


def main() -> None:
    if not FIFO_PATH:
        print("Usage: tui.py <fifo-path> [log-file]", file=sys.stderr)
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

    threading.Thread(target=reader_thread,         args=(FIFO_PATH, state),    daemon=True).start()
    if VERBOSE_LOG:
        threading.Thread(target=verbose_reader_thread, args=(VERBOSE_LOG, state), daemon=True).start()

    act_lines = 20
    vrb_lines = 15
    try:
        with Live(state.render(), console=console, refresh_per_second=4, screen=False) as live:
            while not state.finished:
                body_h    = max(10, console.size.height - 6)
                total_r   = ACTIVITY_RATIO + 2
                act_lines = max(5,  body_h * ACTIVITY_RATIO // total_r - 2)
                vrb_lines = max(3,  body_h * 2             // total_r - 2)
                live.update(state.render(activity_lines=act_lines, verbose_lines=vrb_lines))
                time.sleep(0.25)
            # state.finished is True — exit Live immediately. setup-lab.sh's
            # _at_exit trap clears the screen and prints the authoritative
            # completion banner with the full per-component breakdown.
    except Exception:
        pass  # never let a Rich crash hide the bash-side banner that follows

    # Aggressively reset terminal state on exit so the bash banner that
    # follows is guaranteed visible. We bypass sys.stdout (which Rich may
    # have left in a quirky state) and write straight to /dev/tty.
    try:
        with open("/dev/tty", "w") as _tty:
            _tty.write("\033[?1049l\033[?25h\033[0m\r\n")
            _tty.flush()
    except OSError:
        pass


if __name__ == "__main__":
    main()
