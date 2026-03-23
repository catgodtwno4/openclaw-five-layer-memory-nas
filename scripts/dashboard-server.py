#!/usr/bin/env python3
"""Dashboard Server — Session Auth + Rate Limiting + User Management + Data API"""
import http.server, http.cookies, os, time, json, secrets, urllib.parse, urllib.request, subprocess, threading, re, sqlite3, base64
from collections import defaultdict

PORT = 8090
BIND = "127.0.0.1"
SERVE_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPTS_DIR = os.path.expanduser("~/.openclaw/workspace/scripts")
WORKSPACE_DIR = os.path.expanduser("~/.openclaw/workspace")

USERS_FILE = os.path.join(SERVE_DIR, "users.json")
TODO_FILE  = os.path.expanduser("~/.openclaw-data/shared-data/todo.md")
PROGRESS_FILE = os.path.expanduser("~/.openclaw-data/shared-data/progress-log.md")
MEMORY_FILE = "/tmp/memory-dashboard-data.json"
QMD_DB = os.path.expanduser("~/.openclaw/agents/main/qmd/xdg-cache/qmd/index.sqlite")

NEO4J_URL  = "http://10.10.10.66:7474"
NEO4J_USER = "neo4j"
NEO4J_PASS = "openclaw2026"

CF_TOKEN_FILE = os.path.expanduser("~/.openclaw/.cf-access-token")
CF_ACCOUNT_ID = "555d2d49ac6f932b0513cce036e1ab45"
CF_APP_ID     = "8856d51e-9682-4f42-8765-0dea307ecd36"

SESSION_DURATION = 86400
sessions   = {}
fail_counts = defaultdict(list)
MAX_FAILS  = 5
FAIL_WINDOW = 60
_refreshing = False
_users_lock = threading.Lock()

# Valid roles
VALID_ROLES = ("admin", "task_manager", "viewer")

# ── Default users (created on first run) ────────────────────────────────────

DEFAULT_USERS = [
    {
        "email": "catgodtw@gmail.com",
        "role": "admin",
        "createdAt": "2026-03-23T10:00:00Z",
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

def _find_user_by_email(users, email):
    return next((u for u in users if u.get("email", "").lower() == email.lower()), None)

def _validate_email(email):
    return re.match(r'^[^@\s]+@[^@\s]+\.[^@\s]+$', email) is not None

# ── Cloudflare Access API helpers ─────────────────────────────────────────────

def _read_cf_token():
    """Read CF API token from file."""
    if not os.path.exists(CF_TOKEN_FILE):
        return None
    with open(CF_TOKEN_FILE) as f:
        return f.read().strip()

def _cf_get_policy_id(token):
    """Fetch the first policy ID for the Access app."""
    url = f"https://api.cloudflare.com/client/v4/accounts/{CF_ACCOUNT_ID}/access/apps/{CF_APP_ID}/policies"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            policies = data.get("result", [])
            if policies:
                return policies[0]["id"]
    except Exception as e:
        print(f"[CF] Failed to get policy ID: {e}")
    return None

def _cf_sync_policy(user_emails):
    """Update CF Access policy to allow exactly the given list of emails."""
    token = _read_cf_token()
    if not token:
        print("[CF] No token found, skipping policy sync")
        return False

    policy_id = _cf_get_policy_id(token)
    if not policy_id:
        print("[CF] Could not get policy ID, skipping sync")
        return False

    include = [{"email": {"email": e}} for e in user_emails if e]
    payload = json.dumps({"include": include}).encode()
    url = f"https://api.cloudflare.com/client/v4/accounts/{CF_ACCOUNT_ID}/access/apps/{CF_APP_ID}/policies/{policy_id}"
    req = urllib.request.Request(url, data=payload, method="PUT", headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read().decode())
            if result.get("success"):
                print(f"[CF] Policy synced with {len(include)} email(s)")
                return True
            else:
                print(f"[CF] Policy sync failed: {result.get('errors')}")
    except Exception as e:
        print(f"[CF] Policy sync error: {e}")
    return False

def _cf_sync_async(user_emails):
    """Run CF policy sync in background thread."""
    threading.Thread(target=_cf_sync_policy, args=(list(user_emails),), daemon=True).start()

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
    '.footer{text-align:center;color:#475569;font-size:11px;margin-top:20px}'
    '.cf-note{text-align:center;color:#64748b;font-size:12px;margin-top:12px}'
    '</style></head><body>'
    '<div class="card"><h1>OpenClaw</h1><div class="sub">Dashboard</div>'
    '<div class="error" id="err">__ERROR__</div>'
    '<div class="cf-note">🔐 Authentication via Cloudflare Access</div>'
    '<div class="footer">Secured via Cloudflare Tunnel + HTTPS</div></div></body></html>'
)

# ── Markdown parsers ──────────────────────────────────────────────────────────

def parse_todo(path):
    """Parse todo.md into structured task list with metadata support.

    Supported metadata line format (after ### header):
        > 📅 2026-03-23 | ⏰ 2026-03-25 | 👤 scott | 🏷️ 進行中
    """
    tasks = []
    if not os.path.exists(path):
        return tasks
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    # Map section header keywords → status
    SECTION_STATUS_MAP = {
        "進行中": "in_progress", "In Progress": "in_progress",
        "已完成": "done",        "Done": "done", "Completed": "done",
        "待處理": "pending",     "待辦": "pending", "Pending": "pending",
        "阻塞": "blocked",       "Blocked": "blocked",
    }
    # Map 🏷️ label values → status
    LABEL_STATUS_MAP = {
        "進行中": "in_progress",
        "已完成": "done",
        "待辦":   "pending",
        "阻塞":   "blocked",
    }

    category      = None
    current_task  = None
    section_status = None

    for line in lines:
        line = line.rstrip("\n")

        # ## Category header
        h2 = re.match(r'^##\s+(.+)$', line)
        if h2 and not line.startswith('###'):
            category = h2.group(1).strip()
            current_task = None
            section_status = None
            for k, v in SECTION_STATUS_MAP.items():
                if k in category:
                    section_status = v
                    break
            continue

        # ### [P1] Title (AUTO) or ### [P2] Title
        h3 = re.match(r'^###\s+(\[P(\d)\])?\s*(.*?)(\s*\(AUTO\))?\s*$', line)
        if h3:
            priority = h3.group(2) or "0"
            title    = h3.group(3).strip()
            auto     = h3.group(4) is not None
            current_task = {
                "title":       title,
                "category":    category,
                "priority":    f"P{priority}",
                "auto":        auto,
                "status":      section_status or "pending",
                "subtasks":    [],
                "createdDate": None,
                "dueDate":     None,
                "assignee":    None,
                "description": None,
            }
            tasks.append(current_task)
            continue

        if current_task is not None:
            # > metadata line: > 📅 2026-03-23 | ⏰ 2026-03-25 | 👤 scott | 🏷️ 進行中
            meta_m = re.match(r'^>\s*(.+)$', line)
            if meta_m:
                meta_text = meta_m.group(1)
                cd = re.search(r'📅\s*(\d{4}-\d{2}-\d{2})', meta_text)
                if cd:
                    current_task['createdDate'] = cd.group(1)
                dd = re.search(r'⏰\s*(\d{4}-\d{2}-\d{2})', meta_text)
                if dd:
                    current_task['dueDate'] = dd.group(1)
                av = re.search(r'👤\s*(\S+)', meta_text)
                if av:
                    current_task['assignee'] = av.group(1)
                sv = re.search(r'🏷️\s*(.+?)(?:\s*\||\s*$)', meta_text)
                if sv:
                    status_raw = sv.group(1).strip()
                    mapped = LABEL_STATUS_MAP.get(status_raw)
                    if mapped:
                        current_task['status'] = mapped
                # Description line: > 📝 text
                desc_m = re.search(r'📝\s*(.+)', meta_text)
                if desc_m:
                    current_task['description'] = desc_m.group(1).strip()
                continue

            # - [x] or - [ ] subtasks
            done_m = re.match(r'^\s*-\s+\[x\]\s+(.+)$', line, re.IGNORECASE)
            todo_m = re.match(r'^\s*-\s+\[ \]\s+(.+)$', line)
            if done_m:
                current_task["subtasks"].append({"text": done_m.group(1).strip(), "done": True})
            elif todo_m:
                current_task["subtasks"].append({"text": todo_m.group(1).strip(), "done": False})

    # Overdue detection
    today = time.strftime("%Y-%m-%d")
    for t in tasks:
        due = t.get("dueDate")
        if due and due < today and t.get("status") not in ("done",):
            t["isOverdue"] = True
        else:
            t["isOverdue"] = False

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


def _neo4j_query(statement):
    """Execute a Cypher query against Neo4j REST API. Returns rows list or raises."""
    url = f"{NEO4J_URL}/db/neo4j/tx/commit"
    payload = json.dumps({"statements": [{"statement": statement}]}).encode("utf-8")
    creds = base64.b64encode(f"{NEO4J_USER}:{NEO4J_PASS}".encode()).decode()
    req = urllib.request.Request(url, data=payload, method="POST", headers={
        "Authorization": f"Basic {creds}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    errors = data.get("errors", [])
    if errors:
        raise RuntimeError(f"Neo4j error: {errors[0].get('message', str(errors[0]))}")
    results = data.get("results", [])
    if not results:
        return []
    columns = results[0].get("columns", [])
    rows = []
    for row in results[0].get("data", []):
        rows.append(dict(zip(columns, row.get("row", []))))
    return rows


# ── Handler ───────────────────────────────────────────────────────────────────

class DashboardHandler(http.server.SimpleHTTPRequestHandler):

    def end_headers(self):
        """Add cache headers based on path."""
        path = self.path.split('?')[0] if hasattr(self, 'path') else ''
        if path.startswith('/api/'):
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        elif path.endswith('.html') or path == '/' or path == '':
            self.send_header("Cache-Control", "public, max-age=600, s-maxage=600")
        super().end_headers()

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
        # Auto-login via Cloudflare Access (CF-Access-Authenticated-User-Email header)
        # Bypass auth for localhost/proxy requests (Next.js proxy)
        if self.client_address[0] in ('127.0.0.1', '::1', 'localhost'):
            forwarded = self.headers.get("X-Forwarded-For", "")
            if not forwarded:
                return {"user": "system", "role": "admin", "expires": time.time() + 86400, "ip": "localhost"}
        cf_email = self.headers.get("Cf-Access-Authenticated-User-Email", "")
        if cf_email:
            # Look up user by email in users.json to get their role
            users = _load_users()
            user = _find_user_by_email(users, cf_email)
            role = user.get("role", "viewer") if user else "viewer"
            return {
                "user": cf_email,
                "role": role,
                "expires": time.time() + SESSION_DURATION,
                "ip": cf_email,
            }
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

    def _require_task_manager_or_admin(self):
        """Returns session if admin or task_manager, else sends 403 and returns None."""
        sess = self._require_auth()
        if not sess:
            return None
        if sess.get("role") not in ("admin", "task_manager"):
            self._send_json(403, {"error": "forbidden", "detail": "admin or task_manager role required"})
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
        if path == "/api/memory/files":
            self._handle_memory_files(); return
        if path == "/api/memory/file":
            self._handle_memory_file(); return
        if path == "/api/qmd/documents":
            self._handle_qmd_documents(); return
        if path == "/api/graph/nodes":
            self._handle_graph_nodes(); return

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
        if path == "/api/tasks":
            self._handle_tasks_create(); return
        self.send_response(405); self.end_headers()

    def do_PUT(self):
        path = self.path.split("?")[0]
        # /api/tasks/:index
        m = re.match(r'^/api/tasks/(\d+)$', path)
        if m:
            self._handle_tasks_update(int(m.group(1))); return
        # /api/users/:email
        m = re.match(r'^/api/users/([^/?]+)', self.path)
        if m:
            self._handle_users_update(urllib.parse.unquote(m.group(1))); return
        self.send_response(405); self.end_headers()

    def do_DELETE(self):
        path = self.path.split("?")[0]
        # /api/tasks/:index
        m = re.match(r'^/api/tasks/(\d+)$', path)
        if m:
            self._handle_tasks_delete(int(m.group(1))); return
        # /api/users/:email
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
        """Legacy login form handler — mostly unused since CF Access handles auth."""
        self.send_response(302)
        self.send_header("Location", "/")
        self.end_headers()

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
        # Overdue detection: mark tasks whose dueDate is in the past and not done
        today = time.strftime("%Y-%m-%d")
        for t in tasks:
            due = t.get("dueDate")
            status = t.get("status", "pending")
            if due and due < today and status not in ("done",):
                t["isOverdue"] = True
            else:
                t["isOverdue"] = False
        self._send_json(200, {"tasks": tasks, "progress": progress, "memory": memory, "users": _load_users()})

    # ── Memory Tab API ────────────────────────────────────────────────────────

    def _handle_memory_files(self):
        """List all .md files in the workspace directory."""
        if not self._require_auth():
            return
        files = []
        workspace = os.path.realpath(WORKSPACE_DIR)
        if not os.path.isdir(workspace):
            self._send_json(200, []); return
        for fname in sorted(os.listdir(workspace)):
            if not fname.endswith(".md"):
                continue
            fpath = os.path.join(workspace, fname)
            # Security: only files directly in workspace (no subdirs traversal)
            real = os.path.realpath(fpath)
            if not real.startswith(workspace + os.sep) and real != workspace:
                continue
            try:
                stat = os.stat(fpath)
                files.append({
                    "name": fname,
                    "size": stat.st_size,
                    "modifiedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stat.st_mtime)),
                })
            except OSError:
                pass
        self._send_json(200, files)

    def _handle_memory_file(self):
        """Read a single .md file from the workspace (first 2000 chars)."""
        if not self._require_auth():
            return
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        path_param = qs.get("path", [""])[0]
        if not path_param:
            self._send_json(400, {"error": "path parameter required"}); return
        # Security: strip any directory components, only allow filename
        fname = os.path.basename(path_param)
        if not fname.endswith(".md"):
            self._send_json(400, {"error": "only .md files are allowed"}); return
        workspace = os.path.realpath(WORKSPACE_DIR)
        fpath = os.path.realpath(os.path.join(workspace, fname))
        # Path traversal check
        if not fpath.startswith(workspace + os.sep) and fpath != workspace:
            self._send_json(403, {"error": "access denied"}); return
        if not os.path.isfile(fpath):
            self._send_json(404, {"error": "file not found"}); return
        try:
            with open(fpath, encoding="utf-8") as f:
                content = f.read(2000)
            self._send_json(200, {"name": fname, "content": content, "truncated": os.path.getsize(fpath) > 2000})
        except OSError as e:
            self._send_json(500, {"error": str(e)})

    # ── QMD Documents API ─────────────────────────────────────────────────────

    def _handle_qmd_documents(self):
        """GET /api/qmd/documents — list all QMD indexed documents from SQLite."""
        if not self._require_auth():
            return
        if not os.path.exists(QMD_DB):
            self._send_json(200, []); return
        try:
            conn = sqlite3.connect(QMD_DB, timeout=5)
            conn.row_factory = sqlite3.Row
            cur = conn.cursor()
            cur.execute(
                "SELECT id, collection, path, title, hash, created_at, modified_at, active "
                "FROM documents ORDER BY modified_at DESC"
            )
            rows = cur.fetchall()
            conn.close()
            docs = []
            for r in rows:
                docs.append({
                    "id": r["id"],
                    "path": r["path"],
                    "title": r["title"],
                    "collection": r["collection"],
                    "hash": r["hash"],
                    "createdAt": r["created_at"],
                    "modifiedAt": r["modified_at"],
                    "active": bool(r["active"]),
                })
            self._send_json(200, docs)
        except sqlite3.Error as e:
            self._send_json(500, {"error": f"SQLite error: {e}"})
        except Exception as e:
            self._send_json(500, {"error": str(e)})

    # ── Graph Data API (Neo4j) ────────────────────────────────────────────────

    def _handle_graph_nodes(self):
        """GET /api/graph/nodes — get graph summary from Neo4j."""
        if not self._require_auth():
            return
        try:
            # 1. Node type counts
            node_rows = _neo4j_query(
                "MATCH (n) RETURN labels(n)[0] as type, count(n) as cnt ORDER BY cnt DESC"
            )
            node_types = [
                {"type": r.get("type"), "count": r.get("cnt")}
                for r in node_rows
            ]

            # 2. Sample memory nodes
            mem_rows = _neo4j_query(
                "MATCH (n:Memory) RETURN n.memory as text, n.memory_type as mtype, n.user_id as user LIMIT 20"
            )
            memories = [
                {"text": r.get("text"), "type": r.get("mtype"), "user": r.get("user")}
                for r in mem_rows
            ]

            # 3. Relationship summary
            rel_rows = _neo4j_query(
                "MATCH (a)-[r]->(b) RETURN labels(a)[0] as from, type(r) as rel, "
                "labels(b)[0] as to, count(*) as cnt ORDER BY cnt DESC LIMIT 20"
            )
            relationships = [
                {"from": r.get("from"), "rel": r.get("rel"), "to": r.get("to"), "count": r.get("cnt")}
                for r in rel_rows
            ]

            self._send_json(200, {
                "nodeTypes": node_types,
                "relationships": relationships,
                "memories": memories,
            })
        except urllib.error.URLError as e:
            self._send_json(503, {"error": f"Neo4j unreachable: {e}"})
        except RuntimeError as e:
            self._send_json(502, {"error": str(e)})
        except Exception as e:
            self._send_json(500, {"error": str(e)})

    # ── User Management API ───────────────────────────────────────────────────

    def _handle_users_list(self):
        if not self._require_admin():
            return
        with _users_lock:
            users = _load_users()
        safe = [{"email": u["email"], "role": u.get("role", "viewer"), "createdAt": u.get("createdAt", "")} for u in users]
        self._send_json(200, safe)

    def _handle_users_create(self):
        if not self._require_admin():
            return
        body = self._read_json_body()
        if body is None:
            return
        email = (body.get("email") or "").strip().lower()
        role  = body.get("role", "viewer")
        if not email:
            self._send_json(400, {"error": "email is required"}); return
        if not _validate_email(email):
            self._send_json(400, {"error": "invalid email format"}); return
        if role not in VALID_ROLES:
            self._send_json(400, {"error": f"role must be one of: {', '.join(VALID_ROLES)}"}); return

        with _users_lock:
            users = _load_users()
            if _find_user_by_email(users, email):
                self._send_json(409, {"error": "user already exists"}); return
            new_user = {
                "email": email,
                "role": role,
                "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            users.append(new_user)
            _save_users(users)
            all_emails = [u["email"] for u in users]

        # Sync CF Access policy in background
        _cf_sync_async(all_emails)
        self._send_json(201, {"email": email, "role": role, "createdAt": new_user["createdAt"]})

    def _handle_users_update(self, email):
        if not self._require_admin():
            return
        body = self._read_json_body()
        if body is None:
            return
        email = email.lower()
        with _users_lock:
            users = _load_users()
            user = _find_user_by_email(users, email)
            if not user:
                self._send_json(404, {"error": "user not found"}); return
            if "role" in body:
                if body["role"] not in VALID_ROLES:
                    self._send_json(400, {"error": f"role must be one of: {', '.join(VALID_ROLES)}"}); return
                user["role"] = body["role"]
            _save_users(users)
            # Refresh in-memory sessions for this user
            for sess in sessions.values():
                if sess.get("user") == email:
                    sess["role"] = user["role"]

        self._send_json(200, {"email": email, "role": user["role"], "createdAt": user.get("createdAt", "")})

    def _handle_users_delete(self, email):
        if not self._require_admin():
            return
        email = email.lower()
        with _users_lock:
            users = _load_users()
            user = _find_user_by_email(users, email)
            if not user:
                self._send_json(404, {"error": "user not found"}); return
            # Prevent deleting the last admin
            admins = [u for u in users if u.get("role") == "admin"]
            if user.get("role") == "admin" and len(admins) <= 1:
                self._send_json(400, {"error": "cannot delete the last admin"}); return
            users = [u for u in users if u.get("email", "").lower() != email]
            _save_users(users)
            all_emails = [u["email"] for u in users]
            # Invalidate sessions for this user
            to_remove = [tok for tok, s in sessions.items() if s.get("user") == email]
            for tok in to_remove:
                del sessions[tok]

        # Sync CF Access policy in background
        _cf_sync_async(all_emails)
        self._send_json(200, {"deleted": email})

    # ── Task Management API ───────────────────────────────────────────────────

    def _handle_tasks_create(self):
        """POST /api/tasks — create a new main task in todo.md (admin or task_manager)."""
        if not self._require_task_manager_or_admin():
            return
        body = self._read_json_body()
        if body is None:
            return

        title    = (body.get("title") or "").strip()
        priority = (body.get("priority") or "P2").strip().upper()
        category = (body.get("category") or "待處理").strip()
        subtasks = body.get("subtasks") or []
        due_date = (body.get("dueDate") or "").strip()
        assignee = (body.get("assignee") or "").strip()
        description = (body.get("description") or "").strip()

        if not title:
            self._send_json(400, {"error": "title is required"}); return
        if priority not in ("P1", "P2", "P3"):
            self._send_json(400, {"error": "priority must be P1, P2, or P3"}); return
        if not isinstance(subtasks, list):
            self._send_json(400, {"error": "subtasks must be an array"}); return

        # Build the new task block
        task_lines = [f"\n### [{priority}] {title}"]
        # Build metadata line if any metadata is provided
        today_str = time.strftime("%Y-%m-%d")
        meta_parts = [f"📅 {today_str}"]
        if due_date:
            meta_parts.append(f"⏰ {due_date}")
        if assignee:
            meta_parts.append(f"👤 {assignee}")
        meta_parts.append("🏷️ 待辦")
        task_lines.append(f"> {' | '.join(meta_parts)}")
        if description:
            task_lines.append(f"> 📝 {description}")
        for st in subtasks:
            if isinstance(st, dict):
                st = st.get("text", "")
            st = str(st).strip()
            if st:
                task_lines.append(f"- [ ] {st}")
        task_block = "\n".join(task_lines) + "\n"

        try:
            # Read existing todo.md or start empty
            if os.path.exists(TODO_FILE):
                with open(TODO_FILE, encoding="utf-8") as f:
                    content = f.read()
            else:
                content = ""

            # Find the ## category section
            section_pattern = re.compile(
                r'^(##\s+' + re.escape(category) + r'\s*)$',
                re.MULTILINE
            )
            match = section_pattern.search(content)

            if match:
                # Insert task block right after the ## section header line
                insert_pos = match.end()
                content = content[:insert_pos] + task_block + content[insert_pos:]
            else:
                # Category not found — append a new section at end
                if not content.endswith("\n"):
                    content += "\n"
                content += f"\n## {category}\n{task_block}"

            os.makedirs(os.path.dirname(TODO_FILE), exist_ok=True)
            with open(TODO_FILE, "w", encoding="utf-8") as f:
                f.write(content)

            self._send_json(201, {
                "created": True,
                "title": title,
                "priority": priority,
                "category": category,
                "subtasks": subtasks,
                "dueDate": due_date or None,
                "assignee": assignee or None,
            })
        except OSError as e:
            self._send_json(500, {"error": f"File error: {e}"})

    def _handle_tasks_delete(self, task_index):
        """DELETE /api/tasks/:index — remove a task from todo.md (admin only)."""
        if not self._require_admin():
            return
        try:
            tasks = parse_todo(TODO_FILE)
            if task_index < 0 or task_index >= len(tasks):
                self._send_json(404, {"error": f"task index {task_index} not found"}); return

            target = tasks[task_index]
            target_title    = target["title"]
            target_priority = target["priority"]

            # Read raw file
            with open(TODO_FILE, encoding="utf-8") as f:
                lines = f.readlines()

            # Find and remove the task block (### header + subtasks)
            new_lines = []
            in_target = False
            removed = False

            for i, line in enumerate(lines):
                stripped = line.rstrip("\n")
                h3 = re.match(r'^###\s+(\[P(\d)\])?\s*(.*?)(\s*\(AUTO\))?\s*$', stripped)
                if h3:
                    priority_str = f"P{h3.group(2)}" if h3.group(2) else "P0"
                    t_title = h3.group(3).strip()
                    if not removed and priority_str == target_priority and t_title == target_title:
                        in_target = True
                        removed = True
                        continue
                    else:
                        in_target = False

                if in_target:
                    # Skip subtask lines, metadata lines, and notes belonging to this task
                    sub_done = re.match(r'^\s*-\s+\[x\]\s+', stripped, re.IGNORECASE)
                    sub_todo = re.match(r'^\s*-\s+\[ \]\s+', stripped)
                    meta_line = re.match(r'^>\s*.+', stripped)
                    if sub_done or sub_todo or meta_line:
                        continue
                    else:
                        # Non-subtask/metadata line — stop skipping
                        in_target = False

                new_lines.append(line)

            with open(TODO_FILE, "w", encoding="utf-8") as f:
                f.writelines(new_lines)

            self._send_json(200, {"deleted": True, "index": task_index, "title": target_title})
        except FileNotFoundError:
            self._send_json(404, {"error": "todo.md not found"})
        except OSError as e:
            self._send_json(500, {"error": f"File error: {e}"})

    def _handle_tasks_update(self, task_index):
        """PUT /api/tasks/:index — toggle subtask completion (admin or task_manager)."""
        if not self._require_task_manager_or_admin():
            return
        body = self._read_json_body()
        if body is None:
            return

        subtask_index = body.get("subtaskIndex")
        done = body.get("done")

        if subtask_index is None or done is None:
            self._send_json(400, {"error": "subtaskIndex and done are required"}); return
        if not isinstance(subtask_index, int) or subtask_index < 0:
            self._send_json(400, {"error": "subtaskIndex must be a non-negative integer"}); return

        try:
            tasks = parse_todo(TODO_FILE)
            if task_index < 0 or task_index >= len(tasks):
                self._send_json(404, {"error": f"task index {task_index} not found"}); return

            target = tasks[task_index]
            if subtask_index >= len(target["subtasks"]):
                self._send_json(404, {"error": f"subtask index {subtask_index} not found"}); return

            target_title    = target["title"]
            target_priority = target["priority"]
            target_subtask  = target["subtasks"][subtask_index]["text"]

            # Read raw file
            with open(TODO_FILE, encoding="utf-8") as f:
                lines = f.readlines()

            new_lines = []
            in_target_task  = False
            task_found      = False
            subtask_counter = 0
            updated         = False

            for line in lines:
                stripped = line.rstrip("\n")
                h3 = re.match(r'^###\s+(\[P(\d)\])?\s*(.*?)(\s*\(AUTO\))?\s*$', stripped)
                if h3:
                    priority_str = f"P{h3.group(2)}" if h3.group(2) else "P0"
                    t_title = h3.group(3).strip()
                    if not task_found and priority_str == target_priority and t_title == target_title:
                        in_target_task = True
                        task_found = True
                        subtask_counter = 0
                    else:
                        in_target_task = False

                if in_target_task and not updated:
                    sub_done = re.match(r'^(\s*-\s+\[)[xX](\]\s+.+)$', stripped)
                    sub_todo = re.match(r'^(\s*-\s+\[) (\]\s+.+)$', stripped)
                    if sub_done or sub_todo:
                        if subtask_counter == subtask_index:
                            # Toggle this line
                            if done:
                                new_line = re.sub(r'^(\s*-\s+\[)[ ](\])', r'\1x\2', line, flags=re.IGNORECASE)
                                if new_line == line:
                                    new_line = re.sub(r'^(\s*-\s+\[)[xX](\])', r'\1x\2', line)
                            else:
                                new_line = re.sub(r'^(\s*-\s+\[)[xX](\])', r'\1 \2', line, flags=re.IGNORECASE)
                            new_lines.append(new_line)
                            updated = True
                            subtask_counter += 1
                            continue
                        subtask_counter += 1

                new_lines.append(line)

            with open(TODO_FILE, "w", encoding="utf-8") as f:
                f.writelines(new_lines)

            self._send_json(200, {
                "updated": updated,
                "taskIndex": task_index,
                "subtaskIndex": subtask_index,
                "done": done,
            })
        except FileNotFoundError:
            self._send_json(404, {"error": "todo.md not found"})
        except OSError as e:
            self._send_json(500, {"error": f"File error: {e}"})

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
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
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
