#!/usr/bin/env python3
"""
AKS Lab Dashboard Server
Serves the lab dashboard and executes lab scripts via SSE, streaming output
line-by-line back to the browser.

Usage (called by setup-lab.sh / resume-lab.sh):
  python3 dashboard-server.py <repo-root>
"""
import http.server, subprocess, os, re, threading, sys, json, time
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT = 9997
REPO_ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).parent.resolve()
DASHBOARD = Path("/tmp/lab-dashboard.html")
ANSI      = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

# In-memory TTL cache so concurrent clients (e.g. multiple browser tabs)
# share a single kubectl invocation per endpoint. Cache key → (expires_at, data, status_code).
_CACHE: dict = {}
_CACHE_LOCK = threading.Lock()

def _cache_get_or_fetch(key: str, ttl: float, fetch_fn) -> tuple[bytes, int]:
    """Return (payload_bytes, http_status). Calls fetch_fn() only if cache miss/expired.
    fetch_fn must return (payload_bytes, http_status)."""
    now = time.monotonic()
    with _CACHE_LOCK:
        cached = _CACHE.get(key)
        if cached and cached[0] > now:
            return cached[1], cached[2]
    # Fetch outside the lock so a slow kubectl doesn't block other endpoints.
    payload, status = fetch_fn()
    with _CACHE_LOCK:
        _CACHE[key] = (now + ttl, payload, status)
    return payload, status

# Scripts and commands the dashboard is allowed to run.
# Keys match the name in GET /exec/<name>.
_PROFILE = os.environ.get("PROFILE", "aks-lab")

_SCRIPTS = REPO_ROOT / "scripts"

COMMANDS = {
    "resume":          ["bash", str(_SCRIPTS / "resume-lab.sh")],
    "pause":           ["minikube", "stop", "-p", _PROFILE],
    "refresh":         ["bash", str(_SCRIPTS / "refresh-lab.sh")],
    "refresh-images":  ["bash", str(_SCRIPTS / "refresh-lab.sh"), "--images"],
    "refresh-restart": ["bash", str(_SCRIPTS / "refresh-lab.sh"), "--restart"],
    "teardown":        ["bash", str(_SCRIPTS / "teardown-lab.sh")],
    "dns":             ["bash", str(REPO_ROOT / "IaC/dns/apply-dns-config.sh")],
    "flux-sync":       ["flux", "reconcile", "kustomization", "flux-apps", "-n", "flux-system", "--with-source"],
    "ado-sync":        ["bash", "-c", "git submodule update --remote ado && git add ado && git diff --cached --quiet ado && echo 'Already up to date.' || git commit -m 'chore: bump ado submodule'"],
    "pods":            ["kubectl", "get", "pods", "-A", "-o", "wide"],
    "nodes":           ["kubectl", "get", "nodes", "-o", "wide"],
    "hpa":             ["kubectl", "get", "hpa", "-A"],
    "verify":          ["bash", str(_SCRIPTS / "verify-lab.sh")],
}

_running: dict = {}
_lock = threading.Lock()

LAB_FEATURE = str(_SCRIPTS / "lab-feature.sh")


def _run_feature_cmd(args: list[str]) -> tuple[int, str]:
    """Run lab-feature.sh with given args, return (returncode, stdout+stderr)."""
    result = subprocess.run(
        ["bash", LAB_FEATURE] + args,
        cwd=str(REPO_ROOT),
        capture_output=True, text=True,
        env={**os.environ, "TERM": "dumb", "NO_COLOR": "1"},
    )
    return result.returncode, result.stdout + result.stderr


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request noise

    def do_GET(self):
        path = urlparse(self.path).path

        # ── Node metrics (JSON) ────────────────────────────────────
        # Cached for 10s — kubectl top nodes can take 1-5s on a slow cluster,
        # and the client polls every 15s; the cache dedupes concurrent tabs.
        if path == "/api/node-metrics":
            def fetch_node_metrics():
                try:
                    result = subprocess.run(
                        ["kubectl", "top", "nodes", "--no-headers"],
                        capture_output=True, text=True, timeout=10,
                    )
                    nodes = []
                    for line in result.stdout.strip().splitlines():
                        parts = line.split()
                        if len(parts) >= 5:
                            nodes.append({
                                "name":    parts[0],
                                "cpu_val": parts[1],
                                "cpu_pct": int(parts[2].rstrip("%")),
                                "mem_val": parts[3],
                                "mem_pct": int(parts[4].rstrip("%")),
                            })
                    return json.dumps(nodes).encode(), 200
                except Exception as e:
                    return json.dumps({"error": str(e)}).encode(), 500
            data, code = _cache_get_or_fetch("node-metrics", 10.0, fetch_node_metrics)
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(data)
            return

        # ── Pod status by namespace (JSON) ──────────────────────────
        # Cached for 15s — kubectl get pods -A -o json is the heaviest call
        # the dashboard makes (full pod list across all namespaces).
        if path == "/api/pod-status":
            def fetch_pod_status():
                try:
                    result = subprocess.run(
                        ["kubectl", "get", "pods", "-A", "-o", "json"],
                        capture_output=True, text=True, timeout=10,
                    )
                    pods = json.loads(result.stdout).get("items", [])
                    ns_status: dict = {}
                    for pod in pods:
                        ns = pod["metadata"]["namespace"]
                        phase = pod.get("status", {}).get("phase", "Unknown")
                        container_statuses = pod.get("status", {}).get("containerStatuses", [])
                        crash = any(
                            cs.get("state", {}).get("waiting", {}).get("reason") in
                            ("CrashLoopBackOff", "Error", "OOMKilled", "ImagePullBackOff", "ErrImagePull")
                            for cs in container_statuses
                        )
                        ready = all(cs.get("ready", False) for cs in container_statuses) if container_statuses else (phase == "Succeeded")
                        if ns not in ns_status:
                            ns_status[ns] = "healthy"
                        if crash or phase == "Failed" or (not ready and phase not in ("Succeeded", "Pending")):
                            ns_status[ns] = "degraded"
                    return json.dumps(ns_status).encode(), 200
                except Exception:
                    return b"{}", 500
            data, code = _cache_get_or_fetch("pod-status", 15.0, fetch_pod_status)
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(data)
            return

        # ── Feature list (JSON) ─────────────────────────────────────
        if path == "/api/features":
            rc, out = _run_feature_cmd(["list-json"])
            try:
                json.loads(out)  # validate
                data = out.strip().encode()
            except Exception:
                data = b"[]"
            self.send_response(200 if rc == 0 else 500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(data)
            return

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

        # ── Feature enable/disable (SSE) ───────────────────────────
        if path.startswith("/api/feature/enable/") or path.startswith("/api/feature/disable/"):
            parts = path.split("/")
            action = parts[3]   # "enable" or "disable"
            comp_id = parts[4] if len(parts) > 4 else ""
            if not comp_id:
                self._text(400, "Missing component id")
                return
            key = f"feature-{action}-{comp_id}"
            with _lock:
                if key in _running:
                    self._text(409, f"{comp_id} {action} already running")
                    return
                _running[key] = True
            self._stream(key, ["bash", LAB_FEATURE, action, comp_id])
            return

        # ── Corp Client VNC connect ────────────────────────────────
        if path == "/api/corp-client/connect":
            try:
                info = subprocess.run(
                    ["multipass", "info", "corp-client", "--format", "json"],
                    capture_output=True, text=True, timeout=10,
                )
                ip = json.loads(info.stdout)["info"]["corp-client"]["ipv4"][0]
                subprocess.Popen(["open", f"vnc://{ip}:5901"])
                self._text(200, f"vnc://{ip}:5901")
            except Exception as e:
                self._text(500, str(e))
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

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.end_headers()

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
        self.send_header("Access-Control-Allow-Origin", "*")
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
