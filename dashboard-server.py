#!/usr/bin/env python3
"""
AKS Lab Dashboard Server
Serves the lab dashboard and executes lab scripts via SSE, streaming output
line-by-line back to the browser.

Usage (called by setup-lab.sh / resume-lab.sh):
  python3 dashboard-server.py <repo-root>
"""
import http.server, subprocess, os, re, threading, sys
from pathlib import Path
from urllib.parse import urlparse

PORT = 9997
REPO_ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).parent.resolve()
DASHBOARD = Path("/tmp/lab-dashboard.html")
ANSI      = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

# Scripts and commands the dashboard is allowed to run.
# Keys match the name in GET /exec/<name>.
_PROFILE = os.environ.get("PROFILE", "aks-lab")

COMMANDS = {
    "resume":    ["bash", str(REPO_ROOT / "resume-lab.sh")],
    "dns":       ["bash", str(REPO_ROOT / "dns-lab/apply-dns-config.sh")],
    "flux-sync": ["flux", "reconcile", "kustomization", "flux-apps", "-n", "flux-system", "--with-source"],
    "pods":      ["kubectl", "get", "pods", "-A", "-o", "wide"],
    "nodes":     ["kubectl", "get", "nodes", "-o", "wide"],
    "hpa":       ["kubectl", "get", "hpa", "-A"],
    "pause":     ["minikube", "stop", "-p", _PROFILE],
}

_running: dict = {}
_lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request noise

    def do_GET(self):
        path = urlparse(self.path).path

        # ── Script execution (SSE) ──────────────────────────────────
        if path.startswith("/exec/"):
            name = path[len("/exec/"):]
            if name not in COMMANDS:
                self._text(404, "Unknown command: " + name)
                return
            with _lock:
                if name in _running:
                    self._text(409, name + " is already running")
                    return
                _running[name] = True
            self._stream(name, COMMANDS[name])
            return

        # ── Dashboard HTML ──────────────────────────────────────────
        if not DASHBOARD.exists():
            self._text(404, "Dashboard not found. Run setup-lab.sh or resume-lab.sh first.")
            return
        data = DASHBOARD.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _text(self, code, msg):
        b = msg.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _stream(self, name, cmd):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control",    "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        def emit(line):
            try:
                self.wfile.write(("data: " + line + "\n\n").encode())
                self.wfile.flush()
            except Exception:
                pass

        try:
            env = {**os.environ, "TERM": "dumb", "NO_COLOR": "1"}
            proc = subprocess.Popen(
                cmd, cwd=str(REPO_ROOT),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1, env=env,
            )
            for raw in proc.stdout:
                emit(ANSI.sub("", raw.rstrip()))
            proc.wait()
            emit("__DONE__" + str(proc.returncode))
        except Exception as e:
            emit("__ERROR__" + str(e))
        finally:
            with _lock:
                _running.pop(name, None)


if __name__ == "__main__":
    os.chdir(REPO_ROOT)
    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[dashboard] http://localhost:{PORT}", flush=True)
    server.serve_forever()
