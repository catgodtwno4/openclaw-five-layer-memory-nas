#!/usr/bin/env python3
"""Dashboard Server — Session Auth + Rate Limiting + User Management + Data API"""
import http.server, http.cookies, os, hashlib, time, json, secrets, urllib.parse, subprocess, threading, re
from collections import defaultdict

PORT = 8090
BIND = "127.0.0.1"
SERVE_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPTS_DIR = os.path.expanduser("~/.openclaw/workspace/scripts")

USERS_FILE = os.path.join(SERVE_DIR, "users.json")
TODO_FILE  = os.path.expanduser("~/.openclaw-data/shared-data/todo.md")
PROGRESS_FILE = os.path.expanduser("~/.openclaw-data/shared-data/progress-log.md")
MEMORY_FILE = "/tmp/memory-dashboard-data.json"

SESSION_DURATION = 86400
sessions   = {}
fail_counts = defaultdict(list)
MAX_FAILS  = 5
FAIL_WINDOW = 60
_refreshing = False
_users_lock = threading.Lock()

# ── Default users (created on first run) ────────────────────────────────────

DEFAULT_USERS = [
    {
        "username": "scott",
        "password_hash": hashlib.sha256("openclaw2026".encode()).hexdigest(),
        "role": "admin",
        "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
]

# ── User store helpers ────────────────────────────────────────────────────────

def _load_users():
    if not os.path.exists(USERS_FILE):
        _save_users(DEFAULT_USERS)
        return list(DEFAULT_USERS)
    with open(USERS_FILE) as f:
        return json.load(f)

def _save_users(users):
    os.makedirs(os.path.dirname(USERS_FILE), exist_ok=True)
    with open(USERS_FILE, "w") as f:
        json.dump(users, f, indent=2)

def _find_user(users, username):
    return next((u for u in users if u["username"] == username), None)

def _hash_password(pw):
    return hashlib.sha256(pw.encode()).hexdigest()

# ── Login page ────────────────────────────────────────────────────────────────

LOGIN_PAGE = (
    '<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    '<title>Login - OpenClaw Dashboard</title>'
    '<style>*{margin:0;padding:0;box-sizing:border-box}'
    'body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;'
    'display:flex;justify-content:center;align-items:center;min-height:100vh;padding:20px}'
    '.card{background:#1e293b;border-radius:16px;padding:40px;width:100%;max-width:380px;'
    'border:1px solid rgba(255,255,255,.08);box-shadow:0 16px 48px rgba(0,0,0,.5)}'
    'h1{font-size:28px;text-align:center;margin-bottom:4px}'
    '.sub{text-align:center;color:#94a3b8;font-size:13px;margin-bottom:28px}'
    'label{display:block;font-size:12px;color:#94a3b8;margin-bottom:4px;font-weight:600}'
    'input{width:100%;padding:10px 14px;background:#0f172a;border:1px solid rgba(255,255,255,.1);'
    'border-radius:8px;color:#e2e8f0;font-size:14px;margin-bottom:16px;outline:none;transition:.2s}'
    'input:focus{border-color:#6366f1;box-shadow:0 0 0 3px rgba(99,102,241,.2)}'
    'button{width:100%;padding:12px;background:linear-gradient(135deg,#818cf8,#6366f1);color:white;'
    'border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;transition:.2s}'
    'button:hover{opacity:.9;transform:translateY(-1px)}'
    '.error{background:rgba(239,68,68,.1);border:1px solid rgba(239,68,68,.3);color:#ef4444;'
    'padding:10px;border-radius:8px;font-size:13px;margin-bottom:16px;text-align:center;display:none}'
    '.footer{text-align:center;color:#475569;font-size:11px;margin-top:20px}</style></head><body>'
    '<div class="card"><h1>OpenClaw</h1><div class="sub">Dashboard Login</div>'
    '<div class="error" id="err">__ERROR__</div>'
    '<form method="POST" action="/login"><label>Username</label>'
    '<input name="user" type="text" autocomplete="username" autofocus required>'
    '<label>Password</label><input name="pass" type="password" autocomplete="current-password" required>'
    '<button type="submit">Login</button></form>'
    '<div class="footer">Secured via Cloudflare Tunnel + HTTPS</div></div></body></html>'
)

# ── Markdown parsers ──────────────────────────────────────────────────────────

def parse_todo(path):
    """Parse todo.md into structured task list."""
    tasks = []
    if not os.path.exists(path):
        return tasks
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    category = None
    current_task = None

    for line in lines:
        line = line.rstrip("\n")

        # ## Category header
        h2 = re.match(r'^##\s+(.+)$', line)
        if h2 and not line.startswith('###'):
            category = h2.group(1).strip()
            current_task = None
            continue

        # ### [P1] Title (AUTO) or ### [P2] Title
        h3 = re.match(r'^###\s+(\[P(\d)\])?\s*(.*?)(\s*\(AUTO\))?\s*$', line)
        if h3:
            priority = h3.group(2) or "0"
            title    = h3.group(3).strip()
            auto     = h3.group(4) is not None
            current_task = {
                "title": title,
                "category": category,
                "priority": f"P{priority}",
                "auto": auto,
                "subtasks": [],
            }
            tasks.append(current_task)
            continue

        # - [x] or - [ ] subtasks
        if current_task is not None:
            done_m  = re.match(r'^\s*-\s+\[x\]\s+(.+)$', line, re.IGNORECASE)
            todo_m  = re.match(r'^\s*-\s+\[ \]\s+(.+)$', line)
            if done_m:
                current_task["subtasks"].append({"text": done_m.group(1).strip(), "done": True})
            elif todo_m:
                current_task["subtasks"].append({"text": todo_m.group(1).strip(), "done": False})

    return tasks


def parse_progress(path):
    """Parse progress-log.md into structured entries."""
    entries = []
    if not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    current = None
    # ## YYYY-MM-DD HH:MM — Title
    entry_re = re.compile(r'^##\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s*[—\-]+\s*(.+)$')

    for line in lines:
        line = line.rstrip("\n")
        m = entry_re.match(line)
        if m and not line.startswith('###'):
            current = {"timestamp": m.group(1).strip(), "title": m.group(2).strip(), "items": []}
            entries.append(current)
            continue
        if current is not None:
            bullet = re.match(r'^\s*-\s+(.+)$', line)
            if bullet:
                current["items"].append(bullet.group(1).strip())

    return entries

# ── Handler ───────────────────────────────────────────────────────────────────

class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=SERVE_DIR, **kw)

    # ── Session / auth helpers ────────────────────────────────────────────────

    def _get_session(self):
        cookies = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        token = cookies.get("session")
        if token:
            sess = sessions.get(token.value)
            if sess and sess["expires"] > time.time():
                return sess
            elif sess:
                del sessions[token.value]
        return None

    def _get_client_ip(self):
        return (
            self.headers.get("CF-Connecting-IP")
            or self.headers.get("X-Forwarded-For", "").split(",")[0].strip()
            or self.client_address[0]
        )

    def _is_rate_limited(self, ip):
        now = time.time()
        fail_counts[ip] = [t for t in fail_counts[ip] if now - t < FAIL_WINDOW]
        return len(fail_counts[ip]) >= MAX_FAILS

    def _require_auth(self):
        """Returns session or sends 401 and returns None."""
        sess = self._get_session()
        if not sess:
            self._send_json(401, {"error": "unauthorized"})
        return sess

    def _require_admin(self):
        """Returns session if admin, else sends 403 and returns None."""
        sess = self._require_auth()
        if not sess:
            return None
        if sess.get("role") != "admin":
            self._send_json(403, {"error": "forbidden", "detail": "admin role required"})
            return None
        return sess

    # ── Routing ───────────────────────────────────────────────────────────────

    def do_GET(self):
        path = self.path.split("?")[0]

        if path == "/login":
            self._send_login_page(); return
        if path == "/logout":
            self._handle_logout(); return
        if path == "/api/refresh":
            self._handle_refresh(); return
        if path == "/api/status":
            self._handle_status(); return
        if path == "/api/data":
            self._handle_data(); return
        if path == "/api/users":
            self._handle_users_list(); return

        # Static files — require session
        if not self._get_session():
            self.send_response(302)
            self.send_header("Location", "/login")
            self.end_headers()
            return
        super().do_GET()

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/login":
            self._handle_login(); return
        if path == "/api/refresh":
            self._handle_refresh(); return
        if path == "/api/users":
            self._handle_users_create(); return
        self.send_response(405); self.end_headers()

    def do_PUT(self):
        # /api/users/:username
        m = re.match(r'^/api/users/([^/?]+)', self.path)
        if m:
            self._handle_users_update(urllib.parse.unquote(m.group(1))); return
        self.send_response(405); self.end_headers()

    def do_DELETE(self):
        m = re.match(r'^/api/users/([^/?]+)', self.path)
        if m:
            self._handle_users_delete(urllib.parse.unquote(m.group(1))); return
        self.send_response(405); self.end_headers()

    # ── Auth endpoints ────────────────────────────────────────────────────────

    def _handle_logout(self):
        cookies = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        token = cookies.get("session")
        if token and token.value in sessions:
            del sessions[token.value]
        self.send_response(302)
        self.send_header("Location", "/login")
        c = http.cookies.SimpleCookie()
        c["session"] = ""
        c["session"]["max-age"] = "0"
        self.send_header("Set-Cookie", c["session"].OutputString())
        self.end_headers()

    def _handle_login(self):
        ip = self._get_client_ip()
        if self._is_rate_limited(ip):
            self._send_login_page("Too many failed attempts. Wait 60 seconds.")
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        params = urllib.parse.parse_qs(body)
        username = params.get("user", [""])[0]
        pw       = params.get("pass", [""])[0]

        with _users_lock:
            users = _load_users()
            user = _find_user(users, username)

        if user and user["password_hash"] == _hash_password(pw):
            token = secrets.token_hex(32)
            sessions[token] = {
                "user": username,
                "role": user.get("role", "viewer"),
                "expires": time.time() + SESSION_DURATION,
                "ip": ip,
            }
            c = http.cookies.SimpleCookie()
            c["session"] = token
            c["session"]["httponly"] = True
            c["session"]["secure"]   = True
            c["session"]["samesite"] = "Lax"
            c["session"]["max-age"]  = str(SESSION_DURATION)
            c["session"]["path"]     = "/"
            self.send_response(302)
            self.send_header("Set-Cookie", c["session"].OutputString())
            self.send_header("Location", "/")
            self.end_headers()
        else:
            fail_counts[ip].append(time.time())
            remaining = MAX_FAILS - len(fail_counts[ip])
            self._send_login_page(f"Invalid credentials. {max(remaining, 0)} attempts remaining.")

    # ── Refresh / Status ──────────────────────────────────────────────────────

    def _handle_refresh(self):
        global _refreshing
        if not self._require_auth():
            return
        if _refreshing:
            self._send_json(200, {"status": "already_refreshing"}); return
        _refreshing = True
        def do_refresh():
            global _refreshing
            try:
                for script in ["memory-dashboard.sh", "task-dashboard.sh", "portal-dashboard.sh"]:
                    p = os.path.join(SCRIPTS_DIR, script)
                    if os.path.exists(p):
                        subprocess.run(["bash", p], capture_output=True, timeout=60)
            finally:
                _refreshing = False
        threading.Thread(target=do_refresh, daemon=True).start()
        self._send_json(200, {"status": "refreshing", "message": "Dashboard refresh started"})

    def _handle_status(self):
        if not self._require_auth():
            return
        data_file = os.path.join(SERVE_DIR, "memory-dashboard.html")
        mtime = os.path.getmtime(data_file) if os.path.exists(data_file) else 0
        self._send_json(200, {
            "refreshing": _refreshing,
            "lastUpdate": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(mtime)),
            "uptimeSeconds": int(time.time() - _start_time),
        })

    # ── Data API ──────────────────────────────────────────────────────────────

    def _handle_data(self):
        if not self._require_auth():
            return
        tasks    = parse_todo(TODO_FILE)
        progress = parse_progress(PROGRESS_FILE)
        memory   = {}
        if os.path.exists(MEMORY_FILE):
            try:
                with open(MEMORY_FILE) as f:
                    memory = json.load(f)
            except Exception:
                memory = {}
        self._send_json(200, {"tasks": tasks, "progress": progress, "memory": memory})

    # ── User Management API ───────────────────────────────────────────────────

    def _handle_users_list(self):
        if not self._require_admin():
            return
        with _users_lock:
            users = _load_users()
        safe = [{"username": u["username"], "role": u.get("role", "viewer"), "createdAt": u.get("createdAt", "")} for u in users]
        self._send_json(200, safe)

    def _handle_users_create(self):
        if not self._require_admin():
            return
        body = self._read_json_body()
        if body is None:
            return
        username = (body.get("username") or "").strip()
        password = body.get("password") or ""
        role     = body.get("role", "viewer")
        if not username or not password:
            self._send_json(400, {"error": "username and password required"}); return
        if role not in ("admin", "viewer"):
            self._send_json(400, {"error": "role must be admin or viewer"}); return

        with _users_lock:
            users = _load_users()
            if _find_user(users, username):
                self._send_json(409, {"error": "user already exists"}); return
            new_user = {
                "username": username,
                "password_hash": _hash_password(password),
                "role": role,
                "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            users.append(new_user)
            _save_users(users)

        self._send_json(201, {"username": username, "role": role, "createdAt": new_user["createdAt"]})

    def _handle_users_update(self, username):
        if not self._require_admin():
            return
        body = self._read_json_body()
        if body is None:
            return

        with _users_lock:
            users = _load_users()
            user = _find_user(users, username)
            if not user:
                self._send_json(404, {"error": "user not found"}); return
            if "password" in body and body["password"]:
                user["password_hash"] = _hash_password(body["password"])
            if "role" in body:
                if body["role"] not in ("admin", "viewer"):
                    self._send_json(400, {"error": "role must be admin or viewer"}); return
                user["role"] = body["role"]
            _save_users(users)
            # Refresh in-memory sessions for this user
            for sess in sessions.values():
                if sess.get("user") == username:
                    sess["role"] = user["role"]

        self._send_json(200, {"username": username, "role": user["role"], "createdAt": user.get("createdAt", "")})

    def _handle_users_delete(self, username):
        if not self._require_admin():
            return
        with _users_lock:
            users = _load_users()
            user = _find_user(users, username)
            if not user:
                self._send_json(404, {"error": "user not found"}); return
            # Prevent deleting the last admin
            admins = [u for u in users if u.get("role") == "admin"]
            if user.get("role") == "admin" and len(admins) <= 1:
                self._send_json(400, {"error": "cannot delete the last admin"}); return
            users = [u for u in users if u["username"] != username]
            _save_users(users)
            # Invalidate sessions for this user
            to_remove = [tok for tok, s in sessions.items() if s.get("user") == username]
            for tok in to_remove:
                del sessions[tok]

        self._send_json(200, {"deleted": username})

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self._send_json(400, {"error": "empty body"}); return None
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid JSON"}); return None

    def _send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def _send_login_page(self, error=""):
        html = LOGIN_PAGE.replace("__ERROR__", error)
        if error:
            html = html.replace("display:none", "display:block")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def log_message(self, fmt, *args):
        pass  # suppress default access log noise

# ── Entry point ───────────────────────────────────────────────────────────────

_start_time = time.time()

if __name__ == "__main__":
    # Ensure users.json exists on startup
    with _users_lock:
        _load_users()
    server = http.server.HTTPServer((BIND, PORT), DashboardHandler)
    print(f"[dashboard] Listening on {BIND}:{PORT}")
    server.serve_forever()
