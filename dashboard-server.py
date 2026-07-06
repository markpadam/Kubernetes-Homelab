#!/usr/bin/env python3
"""
AKS Lab Dashboard Server
Serves the lab dashboard and executes lab scripts via SSE, streaming output
line-by-line back to the browser.

Usage (called by setup-lab.sh / resume-lab.sh):
  python3 dashboard-server.py <repo-root>
"""
import http.server, subprocess, os, re, secrets, threading, sys, json, time, sqlite3, uuid
from http.cookies import SimpleCookie
from pathlib import Path
from urllib.parse import urlparse, parse_qs

SCENARIOS_FILE = Path(__file__).parent / "scenarios" / "scenarios.json"
DB_FILE = Path(__file__).parent / ".lab-data" / "lab-progress.db"

def _db():
    DB_FILE.parent.mkdir(exist_ok=True)
    conn = sqlite3.connect(str(DB_FILE))
    conn.row_factory = sqlite3.Row
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS progress (
            scenario_id  TEXT PRIMARY KEY,
            status       TEXT,
            attempts     INTEGER DEFAULT 0,
            completed_at TEXT,
            score_pct    REAL
        );
        CREATE TABLE IF NOT EXISTS exam_sessions (
            id               TEXT PRIMARY KEY,
            track            TEXT,
            started_at       TEXT,
            duration_minutes INTEGER,
            submitted_at     TEXT,
            score_pct        REAL,
            passed           INTEGER,
            snapshot         TEXT
        );
    """)
    conn.commit()
    return conn

def _load_scenarios():
    if not SCENARIOS_FILE.exists():
        return []
    try:
        return json.loads(SCENARIOS_FILE.read_text())
    except Exception:
        return []

def _run_check(check: dict, timeout: int = 15) -> dict:
    """Run a single validation check and return {passed, message, output}."""
    cmd = check.get("command", "")
    match_type = check.get("match_type", "contains")
    expected = check.get("expected", "")
    msg = check.get("message", "Check failed")
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        output = (result.stdout or result.stderr or "").strip()
    except subprocess.TimeoutExpired:
        return {"passed": False, "message": f"Timed out after {timeout}s", "output": ""}
    except Exception as e:
        return {"passed": False, "message": str(e), "output": ""}

    if match_type == "exact":
        passed = output == expected
    elif match_type == "contains":
        passed = expected in output
    elif match_type == "not_contains":
        passed = expected not in output
    elif match_type == "regex":
        passed = bool(re.search(expected, output))
    else:
        passed = False

    return {"passed": passed, "message": msg if not passed else "OK", "output": output}

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

        # ── Progress ───────────────────────────────────────────────
        if path == "/api/progress":
            with _db() as conn:
                rows = conn.execute("SELECT * FROM progress").fetchall()
            data = json.dumps([dict(r) for r in rows]).encode()
            self._send_json(200, data)
            return

        # ── Exam session report ────────────────────────────────────
        if path.startswith("/api/exam/") and path.endswith("/report"):
            sid = path[len("/api/exam/"):-len("/report")]
            with _db() as conn:
                row = conn.execute("SELECT * FROM exam_sessions WHERE id=?", (sid,)).fetchone()
            if not row:
                self._text(404, "Session not found")
                return
            self._send_json(200, json.dumps(dict(row)).encode())
            return

        # ── Scenarios list ─────────────────────────────────────────
        if path == "/api/scenarios":
            scenarios = _load_scenarios()
            summary = [
                {k: s[k] for k in ("id", "title", "exam_track", "type", "difficulty", "weight")
                 if k in s}
                for s in scenarios
            ]
            data = json.dumps(summary).encode()
            self._send_json(200, data)
            return

        # ── Single scenario ────────────────────────────────────────
        if path.startswith("/api/scenarios/"):
            sid = path[len("/api/scenarios/"):]
            scenarios = _load_scenarios()
            match = next((s for s in scenarios if s.get("id") == sid), None)
            if not match:
                self._text(404, f"Scenario '{sid}' not found")
                return
            self._send_json(200, json.dumps(match).encode())
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

        # ── Docs listing ──────────────────────────────────────────
        if path == "/api/docs":
            docs_root = REPO_ROOT / "docs"
            docs = []
            category_map = {
                "services":  "Services",
                "guides":    "Guides",
                "cli":       "CLI Tools",
                "iac":       "IaC",
                "tools":     "Tools",
            }
            for md_file in sorted(docs_root.rglob("*.md")):
                rel = md_file.relative_to(docs_root)
                parts = rel.parts
                if len(parts) == 1:
                    category = "Overview"
                elif parts[0] == "guides" and len(parts) > 2 and parts[1] == "incidenthub":
                    category = "IncidentHub"
                else:
                    category = category_map.get(parts[0], parts[0].title())
                stem = md_file.stem
                if stem.upper() == "README":
                    title = (rel.parts[-2].replace("-", " ").title() + " — Index") if len(parts) > 1 else "Overview"
                else:
                    title = re.sub(r"^\d+-", "", stem).replace("-", " ").title()
                docs.append({"path": str(rel), "title": title, "category": category})
            self._send_json(200, json.dumps(docs).encode())
            return

        # ── Doc content ────────────────────────────────────────────
        if path == "/api/docs/content":
            qs = parse_qs(urlparse(self.path).query)
            doc_path = (qs.get("path", [""]) or [""])[0]
            try:
                docs_root = (REPO_ROOT / "docs").resolve()
                target = (docs_root / doc_path).resolve()
                target.relative_to(docs_root)  # raises ValueError if outside docs/
                if not target.is_file() or target.suffix != ".md":
                    self._text(404, "Not found")
                    return
                self._send_json(200, json.dumps({"content": target.read_text()}).encode())
            except (ValueError, OSError):
                self._text(400, "Invalid path")
            return

        self._text(404, "Not found")

    def do_POST(self):
        path = urlparse(self.path).path
        if not self._check_auth():
            return

        # ── Record progress ────────────────────────────────────────
        if path == "/api/progress":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                req = json.loads(body)
            except Exception:
                self._text(400, "Invalid JSON")
                return
            sid = req.get("scenario_id", "")
            status = req.get("status", "completed")
            score = req.get("score_pct", 100.0)
            now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            with _db() as conn:
                conn.execute("""
                    INSERT INTO progress (scenario_id, status, attempts, completed_at, score_pct)
                    VALUES (?, ?, 1, ?, ?)
                    ON CONFLICT(scenario_id) DO UPDATE SET
                        status=excluded.status,
                        attempts=attempts+1,
                        completed_at=excluded.completed_at,
                        score_pct=excluded.score_pct
                """, (sid, status, now, score))
                conn.commit()
            self._send_json(200, b'{"ok":true}')
            return

        # ── Start exam session ─────────────────────────────────────
        if path == "/api/exam/start":
            import random
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                req = json.loads(body)
            except Exception:
                self._text(400, "Invalid JSON")
                return
            track = req.get("track", "CKA")
            try:
                duration = int(req.get("duration_minutes", 120))
                count = int(req.get("count", 20))
            except (TypeError, ValueError):
                self._text(400, "duration_minutes and count must be integers")
                return
            scenarios = _load_scenarios()
            pool = [s for s in scenarios if track in s.get("exam_track", [])]
            count = max(0, min(count, len(pool)))
            selected = random.sample(pool, count)
            session_id = str(uuid.uuid4())[:8]
            now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            with _db() as conn:
                conn.execute(
                    "INSERT INTO exam_sessions (id, track, started_at, duration_minutes) VALUES (?,?,?,?)",
                    (session_id, track, now, duration)
                )
                conn.commit()
            self._send_json(200, json.dumps({
                "session_id": session_id,
                "track": track,
                "duration_minutes": duration,
                "scenarios": [
                    {k: s[k] for k in ("id","title","type","difficulty","weight","exam_track","description","hints","validation_checks","choices","correct_choice","explanation") if k in s}
                    for s in selected
                ]
            }).encode())
            return

        # ── Submit exam session ────────────────────────────────────
        if path.startswith("/api/exam/") and path.endswith("/submit"):
            session_id = path[len("/api/exam/"):-len("/submit")]
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                req = json.loads(body)
            except Exception:
                self._text(400, "Invalid JSON")
                return
            answers = req.get("answers", {})
            scenarios = _load_scenarios()
            scenario_map = {s["id"]: s for s in scenarios}
            total_weight = 0
            earned_weight = 0
            results = []
            for sid, answer in answers.items():
                s = scenario_map.get(sid)
                if not s:
                    continue
                w = s.get("weight", 4)
                total_weight += w
                if s.get("type") == "mcq":
                    correct = answer == s.get("correct_choice")
                    if correct:
                        earned_weight += w
                    results.append({"id": sid, "title": s.get("title",""), "passed": correct, "weight": w})
                else:
                    checks = s.get("validation_checks", [])
                    check_results = [_run_check(c) for c in checks]
                    passed = all(r["passed"] for r in check_results)
                    if passed:
                        earned_weight += w
                    results.append({"id": sid, "title": s.get("title",""), "passed": passed, "weight": w, "checks": check_results})
            score_pct = round((earned_weight / total_weight * 100) if total_weight else 0, 1)
            passed = score_pct >= 66
            now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            with _db() as conn:
                conn.execute("""
                    UPDATE exam_sessions SET submitted_at=?, score_pct=?, passed=?, snapshot=?
                    WHERE id=?
                """, (now, score_pct, int(passed), json.dumps(results), session_id))
                conn.commit()
            self._send_json(200, json.dumps({
                "session_id": session_id,
                "score_pct": score_pct,
                "passed": passed,
                "results": results
            }).encode())
            return

        # ── Scenario validation ────────────────────────────────────
        if path == "/api/validate":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                req = json.loads(body)
            except Exception:
                self._text(400, "Invalid JSON")
                return
            scenario_id = req.get("scenario_id", "")
            scenarios = _load_scenarios()
            scenario = next((s for s in scenarios if s.get("id") == scenario_id), None)
            if not scenario:
                self._text(404, f"Scenario '{scenario_id}' not found")
                return
            checks = scenario.get("validation_checks", [])
            results = [_run_check(c) for c in checks]
            passed = all(r["passed"] for r in results)
            self._send_json(200, json.dumps({"passed": passed, "checks": results}).encode())
            return

        # ── Corp Client VNC connect ────────────────────────────────
        # POST instead of GET — opens an external app, so it's a state change.
        if path == "/api/corp-client/connect":
            try:
                import shutil
                limactl = shutil.which("limactl") or next(
                    (p for p in ("/usr/local/bin/limactl", "/opt/homebrew/bin/limactl")
                     if os.path.exists(p)),
                    "limactl",
                )
                ip_result = subprocess.run(
                    [limactl, "shell", "corp-client", "ip", "-4", "addr", "show", "lima0"],
                    capture_output=True, text=True, timeout=15,
                )
                import re as _re
                m = _re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", ip_result.stdout)
                if not m:
                    raise RuntimeError("Could not determine corp-client IP from lima0 interface")
                ip = m.group(1)
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


WS_PORT = 9998
# The dashboard page (:9997) is the only legitimate WebSocket client.
WS_ALLOWED_ORIGINS = {f"http://localhost:{PORT}", f"http://127.0.0.1:{PORT}", f"http://[::1]:{PORT}"}


def _ws_handshake(ws) -> tuple[str, str]:
    """Return (origin, token) from the WS handshake, across websockets API
    generations: >=14 exposes ws.request.{path,headers}; the legacy API uses
    ws.path / ws.request_headers."""
    req = getattr(ws, "request", None)
    if req is not None:
        path, headers = req.path, req.headers
    else:
        path, headers = getattr(ws, "path", ""), getattr(ws, "request_headers", {})
    origin = headers.get("Origin", "") if headers else ""
    qs = parse_qs(urlparse(path or "").query)
    token = (qs.get("token", [""]) or [""])[0]
    return origin, token


def _start_terminal_ws():
    """WebSocket PTY server on WS_PORT. Each connection spawns a kubectl exec
    shell into the toolbox pod. Messages from the browser are stdin; PTY output
    goes back as text. A JSON resize message {type:'resize',cols:N,rows:N}
    adjusts the PTY window size."""
    try:
        import ptyprocess
    except ImportError:
        print("[terminal] ptyprocess not installed — terminal disabled. Run: pip3 install ptyprocess", flush=True)
        return

    try:
        import asyncio, websockets
    except ImportError:
        print("[terminal] websockets not installed — terminal disabled. Run: pip3 install websockets", flush=True)
        return

    async def handle(ws):
        # Same threat model as the HTTP token check: any webpage in the user's
        # browser can open ws://localhost:9998 (WebSockets are exempt from the
        # same-origin policy), and this socket hands out a SHELL in the cluster.
        # Browsers always send Origin on WS handshakes, so reject foreign pages
        # outright, and require the per-process token (the dashboard appends it
        # via _withToken, same as the SSE endpoints).
        origin, token = _ws_handshake(ws)
        if origin and origin not in WS_ALLOWED_ORIGINS:
            await ws.close(1008, "forbidden origin")
            return
        if not secrets.compare_digest(token, LAB_TOKEN):
            await ws.send("Unauthorized — reload the dashboard page and retry.\r\n")
            await ws.close(1008, "unauthorized")
            return

        # Find the toolbox pod name
        try:
            result = subprocess.run(
                ["kubectl", "get", "pod", "-n", "toolbox", "-l", "app=toolbox",
                 "-o", "jsonpath={.items[0].metadata.name}"],
                capture_output=True, text=True, timeout=10,
            )
            pod = result.stdout.strip()
        except Exception:
            pod = ""

        if not pod:
            await ws.send("No toolbox pod found. Enable the toolbox feature first.\r\n")
            await ws.close()
            return

        cmd = ["kubectl", "exec", "-it", "-n", "toolbox", pod, "--", "/bin/bash"]
        try:
            pty_proc = ptyprocess.PtyProcess.spawn(cmd, dimensions=(24, 200))
        except Exception as e:
            await ws.send(f"Failed to spawn shell: {e}\r\n")
            await ws.close()
            return

        loop = asyncio.get_event_loop()

        async def read_pty():
            while True:
                try:
                    data = await loop.run_in_executor(None, pty_proc.read, 1024)
                    await ws.send(data.decode("utf-8", errors="replace"))
                except Exception:
                    break

        async def write_pty():
            async for msg in ws:
                try:
                    parsed = json.loads(msg)
                    if parsed.get("type") == "resize":
                        pty_proc.setwinsize(parsed.get("rows", 24), parsed.get("cols", 200))
                    continue
                except (json.JSONDecodeError, TypeError):
                    pass
                try:
                    pty_proc.write(msg.encode() if isinstance(msg, str) else msg)
                except Exception:
                    break

        read_task  = asyncio.ensure_future(read_pty())
        write_task = asyncio.ensure_future(write_pty())
        done, pending = await asyncio.wait(
            [read_task, write_task], return_when=asyncio.FIRST_COMPLETED
        )
        for t in pending:
            t.cancel()
        try:
            pty_proc.terminate()
        except Exception:
            pass

    async def main():
        async with websockets.serve(handle, "127.0.0.1", WS_PORT):
            print(f"[terminal] ws://localhost:{WS_PORT}", flush=True)
            await asyncio.Future()

    asyncio.run(main())


# Threading servers: SSE execs (/exec/resume etc.) hold their connection open
# for minutes; a single-threaded server would freeze every dashboard poll for
# the duration. Shared state is already lock-protected (_CACHE_LOCK, _lock).
class _IPv6HTTPServer(http.server.ThreadingHTTPServer):
    address_family = __import__("socket").AF_INET6


if __name__ == "__main__":
    os.chdir(REPO_ROOT)

    ws_thread = threading.Thread(target=_start_terminal_ws, daemon=True)
    ws_thread.start()

    # Bind IPv6 loopback in a background thread so that sshd forwarding
    # localhost:PORT (which resolves ::1 first on macOS) reaches this server
    # instead of any other process that might hold the IPv6 socket.
    try:
        v6_server = _IPv6HTTPServer(("::1", PORT), Handler)
        threading.Thread(target=v6_server.serve_forever, daemon=True).start()
    except OSError:
        pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[dashboard] http://localhost:{PORT}", flush=True)
    server.serve_forever()
