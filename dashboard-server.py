#!/usr/bin/env python3
"""
AKS Lab Dashboard Server
Serves the lab dashboard and executes lab scripts via SSE, streaming output
line-by-line back to the browser.

Usage (called by setup-lab.sh / resume-lab.sh):
  python3 dashboard-server.py <repo-root>
"""
import http.server, subprocess, os, re, secrets, threading, sys, json, time
from http.cookies import SimpleCookie
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT = 9997
REPO_ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).parent.resolve()
DASHBOARD = Path("/tmp/lab-dashboard.html")
ANSI      = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

# Per-process auth token. The browser receives it both as a cookie (set when
# the HTML is served) and as a JS constant (injected into the page), so the
# UI's fetch() and EventSource() calls can both authenticate.
#
# Threat: a malicious page in another browser tab can hit http://localhost:9997
# even though the server is bound to loopback (browsers happily make requests to
# localhost). Without auth, that page could trigger /exec/teardown via <img src>.
# With the token check, the malicious page can't read or guess it, and the
# SameSite=Strict cookie prevents the browser from sending it cross-site.
TOKEN_FILE = Path("/tmp/lab-dashboard-token")
ALLOWED_ORIGINS = {f"http://localhost:{PORT}", f"http://127.0.0.1:{PORT}"}


def _load_or_create_token() -> str:
    # Reuse token across server restarts so existing browser tabs keep working
    # after a resume-lab. File mode 0600 — only the local user can read it.
    if TOKEN_FILE.exists():
        try:
            existing = TOKEN_FILE.read_text().strip()
            if existing and len(existing) >= 32:
                return existing
        except Exception:
            pass
    token = secrets.token_urlsafe(32)
    TOKEN_FILE.write_text(token)
    try:
        os.chmod(TOKEN_FILE, 0o600)
    except Exception:
        pass
    return token


LAB_TOKEN = _load_or_create_token()

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

    # ── Auth helpers ────────────────────────────────────────────
    def _request_token(self) -> str:
        """Pick up the token from cookie, X-Lab-Token header, or ?token= URL param.
        Browser cookies are the primary path (HttpOnly, SameSite=Strict, set when
        the HTML is served). The URL param is the SSE fallback because EventSource
        cannot set custom headers."""
        cookies = SimpleCookie(self.headers.get("Cookie", ""))
        if "lab_token" in cookies:
            return cookies["lab_token"].value
        hdr = self.headers.get("X-Lab-Token", "")
        if hdr:
            return hdr
        qs = parse_qs(urlparse(self.path).query)
        return (qs.get("token", [""]) or [""])[0]

    def _check_auth(self) -> bool:
        """Verify the request carries our token AND (if Origin header is set)
        comes from a trusted origin. Returns True if allowed; otherwise sends a
        401 and returns False."""
        if not secrets.compare_digest(self._request_token(), LAB_TOKEN):
            self._text(401, "Unauthorized")
            return False
        origin = self.headers.get("Origin")
        # Same-origin GET/SSE often omit Origin; only enforce when the browser
        # explicitly states a cross-origin context.
        if origin and origin not in ALLOWED_ORIGINS:
            self._text(403, "Forbidden origin")
            return False
        return True

    # ── Verb dispatch ───────────────────────────────────────────
    def do_GET(self):
        path = urlparse(self.path).path

        # ── Dashboard HTML (public, sets the auth cookie) ──────────
        if path == "/" or path == "/index.html":
            if not DASHBOARD.exists():
                self._text(404, "Dashboard not found. Run setup-lab.sh or resume-lab.sh first.")
                return
            data = self._render_dashboard()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            # HttpOnly so page JS can't read the cookie; SameSite=Strict so the
            # browser refuses to send it from any other site (this is what blocks
            # the <img src="http://localhost:9997/exec/teardown"> CSRF vector).
            self.send_header(
                "Set-Cookie",
                f"lab_token={LAB_TOKEN}; Path=/; HttpOnly; SameSite=Strict",
            )
            self.end_headers()
            self.wfile.write(data)
            return

        # Every other GET endpoint needs auth.
        if not self._check_auth():
            return

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
            self._send_json(code, data)
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
            self._send_json(code, data)
            return

        # ── Feature list (JSON) ─────────────────────────────────────
        if path == "/api/features":
            rc, out = _run_feature_cmd(["list-json"])
            try:
                json.loads(out)  # validate
                data = out.strip().encode()
            except Exception:
                data = b"[]"
            self._send_json(200 if rc == 0 else 500, data)
            return

        # ── Script execution (SSE) ──────────────────────────────────
        # SSE stays GET because EventSource cannot do POST. Token check above
        # has already gated it; SameSite=Strict on the cookie prevents the
        # browser from attaching it to cross-site requests.
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

        self._text(404, "Not found")

    def do_POST(self):
        path = urlparse(self.path).path
        if not self._check_auth():
            return

        # ── Corp Client VNC connect ────────────────────────────────
        # POST instead of GET — opens an external app, so it's a state change.
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

        self._text(404, "Not found")

    def do_OPTIONS(self):
        # No wildcard CORS — we don't want any other origin reading our
        # responses. Only same-origin preflights need a positive answer.
        origin = self.headers.get("Origin", "")
        self.send_response(204)
        if origin in ALLOWED_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Credentials", "true")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "X-Lab-Token, Content-Type")
        self.end_headers()

    # ── Response helpers ────────────────────────────────────────
    def _render_dashboard(self) -> bytes:
        """Inject the auth token into the HTML so the page's JS can attach it
        to API calls. We use a placeholder that setup-lab.sh's template
        emits — if it's not present we just serve the file unchanged."""
        raw = DASHBOARD.read_bytes()
        # The HTML carries window.LAB_TOKEN as the literal string %LAB_TOKEN%
        # before the server sees it; swap in the real value here.
        return raw.replace(b"%LAB_TOKEN%", LAB_TOKEN.encode())

    def _send_json(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        # No CORS header — same-origin reads only.
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
