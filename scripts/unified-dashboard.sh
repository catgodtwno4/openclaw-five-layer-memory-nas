#!/bin/bash
# unified-dashboard.sh — Unified single-page dashboard (Tasks + Memory + Users)
# Generates ~/.openclaw/workspace/unified-dashboard.html
# Runs via cron or manually

set -euo pipefail
OUTDIR="$HOME/.openclaw/workspace"
OUTFILE="$OUTDIR/unified-dashboard.html"
TMPJSON="/tmp/memory-dashboard-data.json"
NOW=$(date '+%Y-%m-%d %H:%M:%S %Z')

# ─── Collect Memory Metrics ───
collect() {
    python3 << 'PYEOF'
import json, subprocess, os, time, sqlite3
from pathlib import Path

def run(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except:
        return ""

def ssh_cmd(cmd, timeout=10):
    return run(f"ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no openclaw@10.10.10.66 \"{cmd}\"", timeout)

def curl_json(url, timeout=10, method="GET", data=None, headers=None):
    cmd = f"curl -sf --max-time {timeout}"
    if headers:
        for k,v in headers.items():
            cmd += f" -H '{k}: {v}'"
    if method == "POST" and data:
        cmd += f" -X POST -H 'Content-Type: application/json' -d '{json.dumps(data)}'"
    cmd += f" '{url}'"
    raw = run(cmd, timeout+2)
    try:
        return json.loads(raw)
    except:
        return None

metrics = {"timestamp": time.strftime("%Y-%m-%d %H:%M:%S %Z"), "epoch": int(time.time())}

# L0: Markdown files
l0_dir = Path.home() / ".openclaw" / "workspace"
l0_files = list(l0_dir.glob("*.md"))
l0_size = sum(f.stat().st_size for f in l0_files)
metrics["l0"] = {
    "status": "ok" if len(l0_files) >= 5 else "warn",
    "files": len(l0_files),
    "size_kb": round(l0_size / 1024, 1),
    "names": sorted([f.name for f in l0_files])
}

# L1: lossless-claw
lcm_db = Path.home() / ".openclaw" / "lcm.db"
l1_count = 0
if lcm_db.exists():
    try:
        conn = sqlite3.connect(str(lcm_db))
        for table in ["summaries", "lcm_entries", "entries"]:
            try:
                l1_count = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                if l1_count > 0: break
            except: pass
        conn.close()
    except: pass

try:
    cfg = json.load(open(str(Path.home() / ".openclaw" / "openclaw.json")))
    l1_model = cfg["plugins"]["entries"]["lossless-claw"]["config"].get("summaryModel", "default")
except:
    l1_model = "unknown"

metrics["l1"] = {
    "status": "ok" if lcm_db.exists() else "error",
    "summaries": l1_count,
    "model": l1_model,
    "db_size_kb": round(lcm_db.stat().st_size / 1024, 1) if lcm_db.exists() else 0
}

# L2: LanceDB Pro
lb_dir = Path.home() / ".openclaw-data" / "memory-lancedb"
l2_files = list(lb_dir.rglob("*.lance")) if lb_dir.exists() else []
try:
    cfg = json.load(open(str(Path.home() / ".openclaw" / "openclaw.json")))
    l2_cfg = cfg["plugins"]["entries"]["memory-lancedb-pro"]["config"]
    l2_retr = l2_cfg.get("retrieval", {})
except:
    l2_cfg = {}; l2_retr = {}

metrics["l2"] = {
    "status": "ok" if len(l2_files) > 0 else "warn",
    "lance_files": len(l2_files),
    "embedding_model": l2_cfg.get("embedding", {}).get("model", "?"),
    "rerank": l2_retr.get("rerank", "none"),
    "halflife_days": l2_retr.get("recencyHalfLifeDays", "?"),
    "recency_weight": l2_retr.get("recencyWeight", "?"),
    "db_size_mb": round(sum(f.stat().st_size for f in l2_files) / 1024 / 1024, 1) if l2_files else 0
}

# L3: QMD
qmd_path = Path.home() / ".openclaw/agents/main/qmd/xdg-cache/qmd/index.sqlite"
l3_docs = 0
if qmd_path.exists():
    try:
        conn = sqlite3.connect(str(qmd_path))
        l3_docs = conn.execute("SELECT COUNT(*) FROM documents").fetchone()[0]
        conn.close()
    except: pass

metrics["l3"] = {
    "status": "ok" if l3_docs > 0 else "warn",
    "documents": l3_docs,
    "engine": "BM25"
}

# L2+: MemOS (NAS)
memos_ok = False
memos_search_ms = -1
try:
    t0 = time.time()
    r = curl_json(f"http://10.10.10.66:8765/product/search", timeout=10, method="POST",
                  data={"query":"health check","user_id":"dashboard","top_k":1},
                  headers={"Content-Type": "application/json"})
    memos_search_ms = int((time.time() - t0) * 1000)
    if r and r.get("code") == 200:
        memos_ok = True
except: pass

DOCKER_BIN = "/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker"
memos_llm = ssh_cmd(f"{DOCKER_BIN} exec oc-memos-api env 2>/dev/null | grep MOS_CHAT_MODEL= | head -1")
memos_llm = memos_llm.replace("MOS_CHAT_MODEL=", "").strip() if memos_llm else "unknown"

metrics["l2plus"] = {
    "status": "ok" if memos_ok else "error",
    "api": "http://10.10.10.66:8765",
    "search_latency_ms": memos_search_ms,
    "llm_model": memos_llm,
    "neo4j": "ok" if run("curl -sf --max-time 3 http://10.10.10.66:7474 -o /dev/null -w '%{http_code}'") == "200" else "error",
    "qdrant": "ok" if run("curl -sf --max-time 3 http://10.10.10.66:6333/collections -o /dev/null -w '%{http_code}'") == "200" else "error"
}

# L4: Cognee (NAS)
cognee_ok = False
cognee_search_ms = -1
try:
    login_r = run("curl -s -X POST http://10.10.10.66:8766/api/v1/auth/login -H 'Content-Type: application/x-www-form-urlencoded' -d 'username=scott@openclaw.ai&password=openclaw2026'")
    token = json.loads(login_r).get("access_token","") if login_r else ""
    if token:
        t0 = time.time()
        sr = run(f"curl -s --max-time 10 -X POST http://10.10.10.66:8766/api/v1/search -H 'Authorization: Bearer {token}' -H 'Content-Type: application/json' -d '{{\"query\":\"health\",\"searchType\":\"CHUNKS\"}}'")
        cognee_search_ms = int((time.time() - t0) * 1000)
        if sr and ('"text"' in sr or "NoData" in sr):
            cognee_ok = True
except: pass

cognee_llm = ssh_cmd(f"{DOCKER_BIN} exec oc-cognee-api env 2>/dev/null | grep LLM_MODEL= | head -1")
cognee_llm = cognee_llm.replace("LLM_MODEL=", "").strip() if cognee_llm else "unknown"

metrics["l4"] = {
    "status": "ok" if cognee_ok else "error",
    "api": "http://10.10.10.66:8766",
    "search_latency_ms": cognee_search_ms,
    "llm_model": cognee_llm
}

# Gateway
gw_raw = run("openclaw status 2>&1 | grep 'critical' | head -1")
gw_crit = 0
if gw_raw:
    import re as _re
    m = _re.search(r'(\d+)\s*critical', gw_raw)
    if m: gw_crit = int(m.group(1))
metrics["gateway"] = {
    "status": "ok" if gw_crit == 0 else "warn",
    "critical_issues": gw_crit
}

# Disk
disk_root = run("df -h / | tail -1 | awk '{print $5}'")
disk_users = run("df -h /Users | tail -1 | awk '{print $5}'")
metrics["disk"] = {"root": disk_root, "users": disk_users}

print(json.dumps(metrics, indent=2, ensure_ascii=False))
PYEOF
}

# ─── Collect Task Data ───
collect_tasks() {
    python3 << 'PYEOF'
import json, re, time, datetime
from pathlib import Path

TODO_PATH = Path.home() / ".openclaw-data" / "shared-data" / "todo.md"
PROGRESS_PATH = Path.home() / ".openclaw-data" / "shared-data" / "progress-log.md"

def parse_todo(content):
    """Parse todo.md with new metadata format support."""
    tasks = []
    current_section = None
    current_task = None

    section_map = {
        "進行中": "in_progress",
        "待處理": "pending",
        "已完成": "done",
        "In Progress": "in_progress",
        "Pending": "pending",
        "Done": "done",
        "Completed": "done",
        "阻塞": "blocked",
        "Blocked": "blocked",
    }

    lines = content.split('\n')

    for line in lines:
        # Section header (## ...)
        m = re.match(r'^##\s+(.+)', line)
        if m:
            sec_name = m.group(1).strip()
            current_section = None
            for k, v in section_map.items():
                if k in sec_name:
                    current_section = v
                    break
            current_task = None
            continue

        # Task header (### [P1/P2/P3] Title)
        m = re.match(r'^###\s+\[?(P[123])\]?\s+(.+)', line)
        if m:
            priority = m.group(1)
            title = m.group(2).strip()
            current_task = {
                "id": len(tasks),
                "priority": priority,
                "title": title,
                "status": current_section or "pending",
                "subtasks": [],
                "category": "General",
                "createdDate": None,
                "dueDate": None,
                "assignee": None,
                "description": None,
                "isOverdue": False,
            }
            tasks.append(current_task)
            continue

        if current_task is not None:
            # Metadata line: > 📅 2026-03-23 | ⏰ 2026-03-25 | 👤 scott | 🏷️ 進行中
            m = re.match(r'^>\s*(.+)', line)
            if m:
                meta_text = m.group(1)
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
                    for k, v in section_map.items():
                        if k == status_raw:
                            current_task['status'] = v
                            break
                desc_m = re.search(r'📝\s*(.+)', meta_text)
                if desc_m:
                    current_task['description'] = desc_m.group(1).strip()
                continue

            # Subtask
            m = re.match(r'^\s*-\s+\[([ xX])\]\s+(.+)', line)
            if m:
                done = m.group(1).lower() == 'x'
                text = m.group(2).strip()
                current_task["subtasks"].append({"done": done, "text": text})
                continue

    # Check overdue: dueDate < today and status != done
    today = datetime.date.today().isoformat()
    for t in tasks:
        due = t.get('dueDate')
        if due and due < today and t.get('status') != 'done':
            t['isOverdue'] = True

    # Guess category from title keywords
    cat_map = [
        (["cloudflare", "CF", "access", "token"], "Infrastructure"),
        (["minimax", "cognee", "memos", "memory", "記憶"], "AI/Memory"),
        (["runbook", "deploy", "部署", "備份", "backup"], "DevOps"),
        (["dashboard", "html", "portal", "viewer"], "Frontend"),
        (["memos-local", "sidecar", "plugin"], "Plugin"),
    ]
    for t in tasks:
        tl = t["title"].lower()
        for keywords, cat in cat_map:
            if any(k.lower() in tl for k in keywords):
                t["category"] = cat
                break

    return tasks

def parse_progress(content):
    entries = []
    lines = content.split('\n')
    current_entry = None
    for line in lines:
        # Date header
        m = re.match(r'^##\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+[—–-]\s+(.+)', line)
        if m:
            current_entry = {
                "date": m.group(1),
                "title": m.group(2).strip(),
                "items": []
            }
            entries.append(current_entry)
            continue
        if current_entry is not None:
            m = re.match(r'^\s*-\s+(.+)', line)
            if m:
                current_entry["items"].append(m.group(1).strip())
    return entries

result = {}

if TODO_PATH.exists():
    todo_content = TODO_PATH.read_text(encoding='utf-8')
    result["tasks"] = parse_todo(todo_content)
else:
    result["tasks"] = []

if PROGRESS_PATH.exists():
    prog_content = PROGRESS_PATH.read_text(encoding='utf-8')
    result["progress"] = parse_progress(prog_content)[:20]  # last 20 entries
else:
    result["progress"] = []

result["users"] = [
    {"email": "scott@example.com", "role": "admin", "createdAt": "2026-03-22"},
]

print(json.dumps(result, indent=2, ensure_ascii=False))
PYEOF
}

echo "Collecting memory metrics..."
MEM_DATA=$(collect 2>/dev/null || echo '{}')
echo "$MEM_DATA" > "$TMPJSON"

echo "Collecting task data..."
TASK_DATA=$(collect_tasks 2>/dev/null || echo '{"tasks":[],"progress":[],"users":[]}')

# ─── Merge all data ───
MERGED_DATA=$(python3 -c "
import json, sys
mem = json.loads('''$MEM_DATA''')
task = json.loads('''$TASK_DATA''')
merged = {**task, 'memory': mem}
print(json.dumps(merged))
" 2>/dev/null || echo '{}')

# ─── Generate HTML ───
python3 - "$OUTFILE" "$NOW" << 'HTMLEOF'
import json, sys

outfile = sys.argv[1]
now = sys.argv[2]

# Read merged data from stdin (we'll embed placeholder, actual fetch from /api/data)
initial_data = {}

html = r"""<!DOCTYPE html>
<html lang="zh-TW">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="refresh" content="600">
<title>OpenClaw Unified Dashboard</title>
<style>
  :root {
    --bg: #0f172a;
    --surface: #1e293b;
    --surface2: #263348;
    --border: #334155;
    --text: #e2e8f0;
    --muted: #94a3b8;
    --accent: #6366f1;
    --accent-light: #818cf8;
    --green: #22c55e;
    --amber: #f59e0b;
    --rose: #f43f5e;
    --blue: #3b82f6;
    --radius: 12px;
    --shadow: 0 4px 24px rgba(0,0,0,0.4);
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    font-size: 14px;
  }

  /* ── Nav ── */
  .nav {
    position: sticky; top: 0; z-index: 100;
    background: rgba(15,23,42,0.92);
    backdrop-filter: blur(12px);
    border-bottom: 1px solid var(--border);
    padding: 0 16px;
    display: flex; align-items: center; gap: 8px;
    height: 52px;
  }
  .nav-brand {
    font-weight: 700; font-size: 15px;
    color: var(--accent-light);
    margin-right: 8px;
    display: flex; align-items: center; gap: 6px;
  }
  .nav-tabs { display: flex; gap: 2px; flex: 1; }
  .nav-tab {
    padding: 6px 14px; border-radius: 8px; border: none;
    background: transparent; color: var(--muted);
    cursor: pointer; font-size: 13px; font-weight: 500;
    transition: all .2s;
  }
  .nav-tab:hover { background: var(--surface2); color: var(--text); }
  .nav-tab.active { background: var(--accent); color: #fff; }
  .nav-right {
    display: flex; align-items: center; gap: 8px;
    margin-left: auto;
  }
  .nav-time {
    font-size: 11px; color: var(--muted);
    white-space: nowrap;
  }
  .btn-icon {
    width: 32px; height: 32px; border-radius: 8px; border: 1px solid var(--border);
    background: var(--surface); color: var(--text);
    cursor: pointer; font-size: 14px;
    display: flex; align-items: center; justify-content: center;
    transition: all .2s;
  }
  .btn-icon:hover { background: var(--surface2); border-color: var(--accent); }
  .i18n-badge {
    font-size: 11px; font-weight: 700;
    padding: 2px 7px; border-radius: 6px;
    border: 1px solid var(--border);
    background: var(--surface); cursor: pointer;
    color: var(--muted); transition: all .2s;
  }
  .i18n-badge:hover { border-color: var(--accent); color: var(--accent); }

  /* ── Content ── */
  .tab-content { display: none; }
  .tab-content.active { display: flex; flex-direction: column; height: calc(100vh - 60px); }
  .page { padding: 16px; max-width: 1400px; margin: 0 auto; width: 100%; }
  #tab-tasks { padding: 0; max-width: 100%; }
  #tab-tasks .page { display: flex; flex-direction: column; flex: 1; min-height: 0; padding: 0; }

  /* ── Stats Row ── */
  .stats-row {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    gap: 12px;
    margin-bottom: 20px;
  }
  .stat-card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 14px;
    text-align: center;
  }
  .stat-label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .5px; margin-bottom: 8px; }
  .stat-value { font-size: 28px; font-weight: 700; line-height: 1; }
  .stat-sub { font-size: 12px; color: var(--muted); margin-top: 4px; }
  .progress-circle {
    width: 60px; height: 60px; margin: 0 auto;
    border-radius: 50%; display: flex; align-items: center; justify-content: center;
    font-weight: 700; font-size: 16px;
    background: conic-gradient(var(--green) 0deg, var(--green) var(--conic-angle, 0deg), var(--border) var(--conic-angle, 0deg), var(--border) 360deg);
    margin-bottom: 8px;
  }
  .progress-circle-inner { width: 54px; height: 54px; border-radius: 50%; background: var(--surface); display: flex; align-items: center; justify-content: center; }

  /* ── Filter Bar ── */
  .filter-bar {
    display: flex; gap: 6px; margin-bottom: 16px; flex-wrap: wrap;
  }
  .filter-btn {
    padding: 6px 12px; border-radius: 8px; border: 1px solid var(--border);
    background: transparent; color: var(--muted);
    cursor: pointer; font-size: 12px; font-weight: 500;
    transition: all .2s;
  }
  .filter-btn:hover { border-color: var(--accent); color: var(--text); }
  .filter-btn.active { background: var(--accent); border-color: var(--accent); color: #fff; }

  /* ── Loading / Error ── */
  .loading-overlay {
    position: fixed; inset: 0; background: rgba(15,23,42,0.85);
    display: flex; align-items: center; justify-content: center;
    z-index: 9999; backdrop-filter: blur(4px);
    flex-direction: column; gap: 12px;
  }
  .spinner {
    width: 36px; height: 36px; border-radius: 50%;
    border: 3px solid var(--border);
    border-top-color: var(--accent);
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
  .error-banner {
    background: rgba(244,63,94,0.1); border: 1px solid var(--rose);
    border-radius: var(--radius); padding: 16px 20px;
    color: var(--rose); text-align: center; margin: 24px auto;
    max-width: 480px;
  }

  /* ── Cards ── */
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 16px;
    transition: border-color .2s, box-shadow .2s;
  }
  .card:hover { border-color: #475569; }

  /* ── Badges ── */
  .badge {
    display: inline-flex; align-items: center;
    padding: 2px 8px; border-radius: 6px;
    font-size: 11px; font-weight: 700; letter-spacing: .4px;
  }
  .badge-p1 { background: rgba(244,63,94,.15); color: #fb7185; border: 1px solid rgba(244,63,94,.3); }
  .badge-p2 { background: rgba(245,158,11,.15); color: #fbbf24; border: 1px solid rgba(245,158,11,.3); }
  .badge-p3 { background: rgba(100,116,139,.15); color: #94a3b8; border: 1px solid rgba(100,116,139,.3); }
  .badge-ok { background: rgba(34,197,94,.15); color: #4ade80; border: 1px solid rgba(34,197,94,.3); }
  .badge-warn { background: rgba(245,158,11,.15); color: #fbbf24; border: 1px solid rgba(245,158,11,.3); }
  .badge-err { background: rgba(244,63,94,.15); color: #fb7185; border: 1px solid rgba(244,63,94,.3); }
  .badge-layer { background: rgba(99,102,241,.2); color: var(--accent-light); border: 1px solid rgba(99,102,241,.35); }
  .badge-cat { background: rgba(59,130,246,.15); color: #60a5fa; border: 1px solid rgba(59,130,246,.3); font-size: 10px; }
  .badge-overdue { background: rgba(244,63,94,.15); color: #fb7185; border: 1px solid rgba(244,63,94,.3); }

  /* ── Progress bar ── */
  .progress-wrap { background: #0f172a; border-radius: 4px; height: 4px; overflow: hidden; }
  .progress-fill { height: 100%; border-radius: 4px; transition: width .4s; }
  .progress-green { background: var(--green); }
  .progress-blue { background: var(--blue); }
  .progress-amber { background: var(--amber); }

  /* ── Tasks Layout ── */
  .tasks-layout { display: flex; flex-direction: column; gap: 12px; flex: 1; min-height: 0; padding: 12px 16px; box-sizing: border-box; }
  .tasks-stats-row {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 8px 16px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
  }
  .tasks-panels {
    display: flex;
    gap: 1px;
    background: var(--border);
    border-radius: 12px;
    overflow: hidden;
    flex: 1;
    min-height: 0;
  }
  .tasks-panels > div {
    flex: 1;
    background: var(--bg);
    overflow-y: auto;
    padding: 0;
  }

  /* ── Three-Panel Layout (Memory) ── */
  .three-panel {
    display: flex;
    gap: 0;
    min-height: 500px;
    height: calc(100vh - 200px);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
    background: var(--surface);
  }
  .panel-left {
    width: 25%;
    min-width: 200px;
    overflow-y: auto;
    border-right: 1px solid var(--border);
    flex-shrink: 0;
  }
  .panel-mid {
    width: 35%;
    overflow-y: auto;
    border-right: 1px solid var(--border);
    flex-shrink: 0;
  }
  .panel-right {
    width: 40%;
    overflow-y: auto;
    flex: 1;
  }
  .panel-header {
    padding: 10px 12px;
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: .8px;
    color: var(--muted);
    border-bottom: 1px solid var(--border);
    font-weight: 600;
    position: sticky; top: 0;
    background: var(--bg);
    z-index: 2;
  }
  .panel-empty {
    display: flex; flex-direction: column;
    align-items: center; justify-content: center;
    height: 200px; gap: 8px;
    color: var(--muted); font-size: 13px; text-align: center;
  }
  .panel-empty div { font-size: 28px; }

  /* ── Compact Inline Stats ── */
  .stats-title { font-size: 14px; font-weight: 700; white-space: nowrap; }
  .stats-sep { color: var(--border); font-size: 16px; }
  .stat-inline { display: flex; align-items: center; gap: 4px; font-size: 13px; font-weight: 600; white-space: nowrap; }
  .stat-inline-label { color: var(--muted); }
  .stat-inline-num { font-weight: 800; }
  .stat-inline.green .stat-inline-num { color: var(--green); }
  .stat-inline.blue .stat-inline-num { color: var(--blue); }
  .stat-inline.amber .stat-inline-num { color: var(--amber); }
  .stat-inline.rose .stat-inline-num { color: var(--rose); }
  .stat-inline.purple .stat-inline-num { color: #a855f7; }
  .stat-dot { color: var(--muted); font-size: 10px; }

  /* ── Compact Task Card (left panel) ── */
  .task-card-compact {
    padding: 8px 10px;
    cursor: pointer;
    transition: all .15s;
    border-left: 3px solid transparent;
    border-bottom: 1px solid rgba(51,65,85,.4);
  }
  .task-card-compact:hover { background: var(--surface2); }
  .task-card-compact.selected {
    background: rgba(99,102,241,.12);
    border-left-color: var(--accent);
  }
  .task-card-compact.status-done { border-left-color: var(--green); }
  .task-card-compact.status-in_progress { border-left-color: var(--blue); }
  .task-card-compact.status-pending { border-left-color: var(--amber); }
  .task-card-compact.status-blocked { border-left-color: var(--rose); }
  .task-card-compact .tc-row1 { display: flex; align-items: center; gap: 6px; margin-bottom: 3px; }
  .task-card-compact .tc-title { font-size: 12px; font-weight: 600; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .task-card-compact .tc-row2 { display: flex; align-items: center; gap: 6px; font-size: 10px; color: var(--muted); }
  .task-card-compact .progress-wrap { margin-top: 4px; }

  /* ── Subtask Checklist (mid panel) ── */
  .subtask-row {
    display: flex; align-items: flex-start; gap: 8px;
    padding: 8px 12px;
    border-bottom: 1px solid rgba(51,65,85,.3);
    font-size: 12px; line-height: 1.5;
  }
  .subtask-row.done { opacity: 0.55; }
  .subtask-row .st-icon { flex-shrink: 0; font-size: 14px; margin-top: 2px; }
  .subtask-row .st-text { flex: 1; }
  .subtask-row .st-text.done-text { text-decoration: line-through; color: var(--muted); }
  .subtask-row .st-meta { font-size: 10px; color: var(--muted); margin-top: 3px; line-height: 1.4; }

  /* ── Task Info (right panel) ── */
  .task-info-section { padding: 14px; }
  .task-info-title { font-size: 16px; font-weight: 700; margin-bottom: 10px; }
  .task-info-badges { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 12px; }
  .task-info-grid { display: grid; grid-template-columns: auto 1fr; gap: 6px 12px; font-size: 12px; margin-bottom: 16px; }
  .task-info-grid .tig-key { color: var(--muted); }
  .task-info-grid .tig-val { font-weight: 500; }
  .task-info-desc { font-size: 12px; color: var(--text); line-height: 1.6; padding: 10px; background: rgba(255,255,255,.02); border-radius: 8px; margin-bottom: 16px; }

  /* ── Progress Timeline (right panel) ── */
  .progress-timeline { padding: 0 14px 14px; }
  .pt-header { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .8px; margin-bottom: 10px; padding-bottom: 6px; border-bottom: 1px solid var(--border); }
  .pt-entry { display: flex; gap: 10px; margin-bottom: 10px; padding-left: 2px; position: relative; }
  .pt-line { position: absolute; left: 3px; top: 12px; bottom: -10px; width: 2px; background: var(--border); }
  .pt-entry:last-child .pt-line { display: none; }
  .pt-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; margin-top: 4px; z-index: 1; }
  .pt-dot-blue { background: var(--blue); }
  .pt-dot-green { background: var(--green); }
  .pt-dot-amber { background: var(--amber); }
  .pt-body { flex: 1; }
  .pt-date { font-size: 10px; color: var(--muted); margin-bottom: 2px; }
  .pt-title { font-size: 12px; font-weight: 600; margin-bottom: 2px; }
  .pt-items { font-size: 11px; color: var(--muted); line-height: 1.5; }

  /* Legacy task card (keep for backward compat) */
  .task-card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 14px;
    cursor: pointer; transition: all .2s;
    border-left: 3px solid transparent;
  }
  .task-card:hover { border-color: #475569; background: var(--surface2); }
  .task-card.selected { border-color: var(--accent); background: rgba(99,102,241,.08); }
  .task-card.status-done { border-left-color: var(--green); }
  .task-card.status-in_progress { border-left-color: var(--blue); }
  .task-card.status-pending { border-left-color: var(--amber); }
  .task-card.status-blocked { border-left-color: var(--rose); }
  .task-card.status-overdue { border-left-color: var(--rose); background: rgba(244,63,94,.04); }
  .task-card-header { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
  .task-title { font-weight: 600; font-size: 13px; flex: 1; }
  .task-meta { display: flex; align-items: center; gap: 6px; margin-bottom: 8px; flex-wrap: wrap; }
  .task-dates { font-size: 10px; color: var(--muted); }
  .task-progress-label { font-size: 11px; color: var(--muted); margin-bottom: 4px; }

  /* Detail panel */
  .detail-empty {
    display: flex; align-items: center; justify-content: center;
    height: 100%; color: var(--muted); font-size: 13px; text-align: center;
  }
  .detail-title {
    font-size: 18px; font-weight: 700; margin-bottom: 12px;
  }
  .detail-header { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-bottom: 16px; }
  .subtask-list { display: flex; flex-direction: column; gap: 8px; margin-bottom: 20px; }
  .subtask-item {
    display: flex; align-items: flex-start; gap: 10px;
    padding: 8px 12px; border-radius: 8px;
    background: rgba(255,255,255,.03);
  }
  .subtask-item.done { opacity: 0.6; }
  .subtask-check {
    width: 18px; height: 18px; border-radius: 5px;
    border: 2px solid var(--border); flex-shrink: 0; margin-top: 1px;
    display: flex; align-items: center; justify-content: center;
    cursor: pointer; transition: all .2s;
  }
  .subtask-check:hover { border-color: var(--accent); }
  .subtask-check.checked { background: var(--accent); border-color: var(--accent); color: #fff; font-size: 11px; }
  .subtask-text { font-size: 13px; line-height: 1.5; }
  .subtask-text.done-text { text-decoration: line-through; color: var(--muted); }

  /* Timeline in detail */
  .timeline-section { margin-top: 20px; }
  .timeline-section h4 { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .8px; margin-bottom: 12px; }
  .timeline-entry {
    display: flex; gap: 12px; margin-bottom: 12px;
    padding-left: 4px;
  }
  .timeline-dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: var(--accent); flex-shrink: 0; margin-top: 5px;
  }
  .timeline-body { flex: 1; }
  .timeline-date { font-size: 11px; color: var(--muted); margin-bottom: 2px; }
  .timeline-title-text { font-size: 13px; font-weight: 600; margin-bottom: 4px; }
  .timeline-items { font-size: 12px; color: var(--muted); line-height: 1.6; }

  /* ── Tab 2: Memory — Three-Panel Layout ── */
  .memory-page { padding: 12px !important; }
  .memory-panels {
    display: flex;
    gap: 0;
    height: calc(100vh - 76px);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    overflow: hidden;
    background: var(--surface);
  }
  /* Left panel */
  .mem-left-panel {
    width: 25%;
    min-width: 180px;
    border-right: 1px solid var(--border);
    overflow-y: auto;
    flex-shrink: 0;
  }
  .mem-panel-header {
    padding: 10px 12px;
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: .8px;
    color: var(--muted);
    border-bottom: 1px solid var(--border);
    font-weight: 600;
  }
  .mem-layer-item {
    display: flex; align-items: center; gap: 8px;
    padding: 10px 12px;
    cursor: pointer;
    transition: all .15s;
    border-left: 3px solid transparent;
    border-bottom: 1px solid rgba(51,65,85,.4);
  }
  .mem-layer-item:hover { background: var(--surface2); }
  .mem-layer-item.selected {
    background: rgba(99,102,241,.12);
    border-left-color: var(--accent);
  }
  .mem-layer-name { font-size: 12px; font-weight: 600; flex: 1; line-height: 1.3; }
  .mem-layer-sub { font-size: 10px; color: var(--muted); }
  .status-dot {
    width: 7px; height: 7px; border-radius: 50%; flex-shrink: 0;
  }
  .dot-ok { background: var(--green); box-shadow: 0 0 4px var(--green); }
  .dot-warn { background: var(--amber); }
  .dot-err { background: var(--rose); }
  /* Middle panel */
  .mem-mid-panel {
    width: 35%;
    border-right: 1px solid var(--border);
    overflow-y: auto;
    flex-shrink: 0;
  }
  /* Right panel */
  .mem-right-panel {
    flex: 1;
    overflow-y: auto;
  }
  /* Panel empty state */
  .mem-panel-empty {
    display: flex; flex-direction: column;
    align-items: center; justify-content: center;
    height: 200px; gap: 8px;
    color: var(--muted); font-size: 13px; text-align: center;
  }
  .mem-panel-empty div { font-size: 28px; }
  /* Middle panel items */
  .mem-mid-item {
    display: flex; align-items: center; gap: 10px;
    padding: 9px 14px;
    cursor: pointer; transition: all .15s;
    border-left: 2px solid transparent;
    border-bottom: 1px solid rgba(51,65,85,.3);
    font-size: 12px;
  }
  .mem-mid-item:hover { background: var(--surface2); }
  .mem-mid-item.selected {
    background: rgba(99,102,241,.1);
    border-left-color: var(--accent);
  }
  .mem-mid-item-name { flex: 1; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .mem-mid-item-meta { color: var(--muted); font-size: 11px; flex-shrink: 0; }
  /* Right panel detail */
  .mem-detail-content { padding: 16px; }
  .mem-detail-title { font-size: 15px; font-weight: 700; margin-bottom: 4px; word-break: break-all; }
  .mem-detail-meta { font-size: 11px; color: var(--muted); margin-bottom: 14px; }
  .mem-detail-preview {
    background: var(--bg); border: 1px solid var(--border);
    border-radius: 8px; padding: 12px;
    font-family: 'SF Mono', 'Menlo', monospace; font-size: 11px;
    color: #cbd5e1; line-height: 1.6; white-space: pre-wrap;
    word-break: break-word; max-height: 300px; overflow-y: auto;
  }
  .mem-kv-list { display: flex; flex-direction: column; gap: 8px; margin-top: 10px; }
  .mem-kv-row { display: flex; justify-content: space-between; align-items: center; padding: 6px 0; border-bottom: 1px solid rgba(51,65,85,.3); font-size: 12px; }
  .mem-kv-row:last-child { border-bottom: none; }
  .mem-kv-key { color: var(--muted); }
  .mem-kv-val { font-weight: 600; color: var(--text); }
  /* Latency gauge */
  .latency-gauge {
    display: flex; align-items: center; gap: 12px; padding: 12px 0;
  }
  .gauge-bar-wrap { flex: 1; background: var(--bg); border-radius: 4px; height: 8px; overflow: hidden; }
  .gauge-bar-fill { height: 100%; border-radius: 4px; transition: width .4s; }
  .gauge-ok { background: var(--green); }
  .gauge-warn { background: var(--amber); }
  .gauge-err { background: var(--rose); }

  /* ── Tab 3: Users ── */
  .users-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
  .users-title { font-size: 16px; font-weight: 700; }
  .cf-access-note {
    display: flex; align-items: flex-start; gap: 8px;
    background: rgba(99,102,241,.08); border: 1px solid rgba(99,102,241,.25);
    border-radius: 10px; padding: 10px 14px; margin-bottom: 16px;
    font-size: 12px; color: #a5b4fc; line-height: 1.5;
  }
  .cf-access-note .note-icon { font-size: 16px; flex-shrink: 0; }
  .btn-primary {
    padding: 8px 16px; border-radius: 8px; border: none;
    background: var(--accent); color: #fff;
    cursor: pointer; font-size: 13px; font-weight: 600;
    transition: all .2s;
  }
  .btn-primary:hover { background: var(--accent-light); }
  .btn-sm {
    padding: 4px 10px; border-radius: 6px; border: 1px solid var(--border);
    background: transparent; color: var(--muted);
    cursor: pointer; font-size: 12px; transition: all .2s;
  }
  .btn-sm:hover { border-color: var(--accent); color: var(--accent); }
  .btn-sm-danger { border-color: rgba(244,63,94,.3); color: var(--rose); }
  .btn-sm-danger:hover { background: rgba(244,63,94,.1); border-color: var(--rose); }
  .users-table { width: 100%; border-collapse: collapse; }
  .users-table th {
    text-align: left; padding: 10px 14px;
    font-size: 11px; font-weight: 600; text-transform: uppercase;
    letter-spacing: .6px; color: var(--muted);
    border-bottom: 1px solid var(--border);
  }
  .users-table td {
    padding: 12px 14px; border-bottom: 1px solid rgba(51,65,85,.5);
    font-size: 13px;
  }
  .users-table tr:last-child td { border-bottom: none; }
  .users-table tr:hover td { background: rgba(255,255,255,.02); }

  /* Modal */
  .modal-overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,.6);
    display: flex; align-items: center; justify-content: center;
    z-index: 999; backdrop-filter: blur(4px);
    opacity: 0; pointer-events: none; transition: opacity .2s;
  }
  .modal-overlay.open { opacity: 1; pointer-events: auto; }
  .modal {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 16px; padding: 24px; width: 360px;
    transform: translateY(-20px); transition: transform .2s;
  }
  .modal-overlay.open .modal { transform: translateY(0); }
  .modal-title { font-size: 16px; font-weight: 700; margin-bottom: 20px; }
  .form-group { margin-bottom: 14px; }
  .form-label { font-size: 12px; color: var(--muted); margin-bottom: 6px; display: block; }
  .form-input {
    width: 100%; padding: 9px 12px; border-radius: 8px;
    border: 1px solid var(--border); background: var(--bg);
    color: var(--text); font-size: 13px; outline: none;
    transition: border-color .2s;
  }
  .form-input:focus { border-color: var(--accent); }
  .form-select {
    width: 100%; padding: 9px 12px; border-radius: 8px;
    border: 1px solid var(--border); background: var(--bg);
    color: var(--text); font-size: 13px; outline: none;
    cursor: pointer;
  }
  .modal-actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 20px; }
  .btn-ghost {
    padding: 8px 16px; border-radius: 8px; border: 1px solid var(--border);
    background: transparent; color: var(--muted);
    cursor: pointer; font-size: 13px; transition: all .2s;
  }
  .btn-ghost:hover { border-color: var(--accent); color: var(--accent); }

  /* Floating refresh */
  .fab {
    position: fixed; bottom: 24px; right: 24px;
    width: 52px; height: 52px; border-radius: 50%;
    background: linear-gradient(135deg, #818cf8, #6366f1);
    color: #fff; border: none; cursor: pointer;
    font-size: 22px; box-shadow: 0 4px 20px rgba(99,102,241,.45);
    display: flex; align-items: center; justify-content: center;
    transition: all .2s; z-index: 998;
  }
  .fab:hover { transform: scale(1.08); box-shadow: 0 6px 24px rgba(99,102,241,.6); }
  .fab:active { transform: scale(0.96); }

  /* Animations */
  @keyframes fadeIn { from { opacity:0; transform:translateY(8px); } to { opacity:1; transform:none; } }
  .fade-in { animation: fadeIn .3s ease both; }

  /* ── Stats Cards ── */
  .stats-row {
    display: grid;
    grid-template-columns: repeat(6, 1fr);
    gap: 10px;
    margin-bottom: 14px;
  }
  @media (max-width: 900px) { .stats-row { grid-template-columns: repeat(3,1fr); } }
  @media (max-width: 560px) { .stats-row { grid-template-columns: repeat(2,1fr); } }
  .stat-card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 12px 10px; text-align: center;
    transition: transform .15s, box-shadow .15s;
  }
  .stat-card:hover { transform: translateY(-2px); box-shadow: var(--shadow); }
  .stat-card.green  { border-color: rgba(34,197,94,.4);  background: rgba(34,197,94,.07); }
  .stat-card.blue   { border-color: rgba(59,130,246,.4); background: rgba(59,130,246,.07); }
  .stat-card.amber  { border-color: rgba(245,158,11,.4); background: rgba(245,158,11,.07); }
  .stat-card.rose   { border-color: rgba(244,63,94,.4);  background: rgba(244,63,94,.07); }
  .stat-card.purple { border-color: rgba(168,85,247,.4); background: rgba(168,85,247,.07); }
  .stat-num { font-size: 22px; font-weight: 800; line-height: 1.1; margin-bottom: 2px; }
  .stat-label { font-size: 11px; color: var(--muted); }
  .stat-card.green  .stat-num { color: var(--green); }
  .stat-card.blue   .stat-num { color: var(--blue); }
  .stat-card.amber  .stat-num { color: var(--amber); }
  .stat-card.rose   .stat-num { color: var(--rose); }
  .stat-card.purple .stat-num { color: #a855f7; }

  /* ── Filter Bar ── */
  .filter-bar { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 12px; }
  .filter-btn {
    padding: 5px 12px; border-radius: 6px;
    border: 1px solid var(--border);
    background: transparent; color: var(--muted);
    cursor: pointer; font-size: 12px; transition: all .15s;
  }
  .filter-btn:hover { border-color: var(--accent); color: var(--accent); }
  .filter-btn.active { background: var(--accent); border-color: var(--accent); color: #fff; font-weight: 600; }

  /* ── Token Injection Bar ── */
  .inject-bar { background: #0f172a; border-radius: 4px; height: 6px; overflow: hidden; margin: 6px 0; }
  .inject-fill { height: 100%; border-radius: 4px; transition: width .6s; }
  .inject-ok   { background: linear-gradient(90deg, #6366f1, #818cf8); }
  .inject-warn { background: linear-gradient(90deg, var(--amber), #fcd34d); }
  .inject-hot  { background: linear-gradient(90deg, var(--rose), #fb923c); }
  .inject-meta { font-size: 10px; color: var(--muted); display: flex; justify-content: space-between; margin-bottom: 6px; }

  /* ── LLM Model Badge ── */
  .badge-anthropic { background: rgba(255,160,50,.12); color: #fb923c; border: 1px solid rgba(255,160,50,.3); }
  .badge-minimax   { background: rgba(168,85,247,.12); color: #c084fc; border: 1px solid rgba(168,85,247,.3); }
  .badge-openai    { background: rgba(34,197,94,.12);  color: #4ade80; border: 1px solid rgba(34,197,94,.3); }

  /* ── Latency Chart ── */
  .latency-chart-section { margin-top: 16px; padding: 14px; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); }
  .latency-chart-title { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .8px; margin-bottom: 12px; }
  .latency-chart { display: flex; align-items: flex-end; gap: 16px; height: 80px; }
  .lc-bar-wrap { display: flex; flex-direction: column; align-items: center; gap: 4px; flex: 1; }
  .lc-bar { width: 100%; border-radius: 4px 4px 0 0; min-height: 4px; }
  .lc-bar-ok   { background: linear-gradient(180deg, #4ade80, #22c55e); }
  .lc-bar-warn { background: linear-gradient(180deg, #fbbf24, #f59e0b); }
  .lc-bar-err  { background: linear-gradient(180deg, #fb7185, #f43f5e); }
  .lc-label { font-size: 10px; color: var(--muted); text-align: center; margin-top: 4px; }
  .lc-val   { font-size: 10px; font-weight: 700; }

  /* ── System Cards Row (Memory Tab) ── */
  .sys-cards-row { display: grid; grid-template-columns: repeat(4,1fr); gap: 12px; margin-top: 16px; }
  @media (max-width: 900px) { .sys-cards-row { grid-template-columns: repeat(2,1fr); } }
  .sys-mini-card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 12px 14px; }
  .sys-mini-title { font-size: 11px; color: var(--muted); margin-bottom: 6px; }
  .sys-mini-val { font-size: 18px; font-weight: 700; margin-bottom: 6px; }
  .sys-mini-status { font-size: 11px; }
  .sys-disk-track { background: #0f172a; border-radius: 3px; height: 5px; overflow: hidden; margin-top: 6px; }
  .sys-disk-fill { height: 100%; border-radius: 3px; }
  .disk-ok  { background: var(--green); }
  .disk-warn { background: var(--amber); }
  .disk-err  { background: var(--rose); }

  /* ── Task Meta Extras ── */
  .task-date-row { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 5px; font-size: 11px; color: var(--muted); align-items: center; }
  .badge-overdue   { background: rgba(244,63,94,.15); color: #fb7185; border: 1px solid rgba(244,63,94,.3); font-size:10px; padding:1px 7px; border-radius:4px; font-weight:600; }
  .badge-assignee  { background: rgba(99,102,241,.12); color: #a5b4fc; border: 1px solid rgba(99,102,241,.25); font-size:10px; padding:1px 7px; border-radius:4px; }

  /* ── Right Panel Sections ── */
  .right-section {
    border-bottom: 1px solid var(--border);
  }
  .right-section-title {
    padding: 8px 14px;
    font-size: 11px;
    font-weight: 700;
    color: var(--text);
    background: rgba(255,255,255,.02);
    border-bottom: 1px solid var(--border);
  }

  /* ── Subtask Filter ── */
  .subtask-filter { display: flex; gap: 6px; margin-bottom: 10px; }
  .subtask-filter-btn { padding: 3px 10px; border-radius: 5px; border: 1px solid var(--border); background: transparent; color: var(--muted); cursor: pointer; font-size: 11px; transition: all .15s; }
  .subtask-filter-btn:hover { border-color: var(--accent); color: var(--accent); }
  .subtask-filter-btn.active { background: var(--accent); border-color: var(--accent); color: #fff; font-weight: 600; }

  /* i18n */
  [data-lang="en"] .i18n-zh { display: none; }
  [data-lang="zh"] .i18n-en { display: none; }

  /* Section headers */
  .section-header { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .8px; margin-bottom: 10px; padding-bottom: 6px; border-bottom: 1px solid var(--border); }

  /* Mobile */
  @media (max-width: 768px) {
    .three-panel {
      flex-direction: column;
      height: auto;
    }
    .panel-left, .panel-mid, .panel-right {
      width: 100%;
      border-right: none;
      border-bottom: 1px solid var(--border);
      max-height: 50vh;
    }
    .tasks-panels {
      flex-direction: column;
      height: auto;
    }
    .tasks-panels > div {
      max-height: 50vh;
    }
    .tasks-stats-row { flex-wrap: wrap; gap: 8px; padding: 6px 10px; }
    .stats-title { font-size: 12px; }
    .stat-inline { font-size: 11px; }
    .memory-panels {
      flex-direction: column;
      height: auto;
    }
    .mem-left-panel, .mem-mid-panel {
      width: 100%;
      border-right: none;
      border-bottom: 1px solid var(--border);
    }
    .mem-right-panel { min-height: 300px; }
    .stats-row { grid-template-columns: repeat(2, 1fr); }
    .nav-time { display: none; }
  }
  @media (max-width: 480px) {
    .stats-row { grid-template-columns: 1fr; }
    .stats-compact { grid-template-columns: repeat(2, 1fr); }
  }

  /* Scrollbar */
  ::-webkit-scrollbar { width: 5px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
</style>
</head>
<body data-lang="zh">

<!-- Loading overlay -->
<div class="loading-overlay" id="loadingOverlay">
  <div class="spinner"></div>
  <div style="color:var(--muted);font-size:13px">
    <span class="i18n-zh">載入資料中...</span>
    <span class="i18n-en">Loading data...</span>
  </div>
</div>

<!-- Nav -->
<nav class="nav">
  <div class="nav-brand">🐕 <span>OpenClaw</span></div>
  <div class="nav-tabs">
    <button class="nav-tab active" onclick="switchTab('tasks', this)">
      <span class="i18n-zh">📋 任務</span><span class="i18n-en">📋 Tasks</span>
    </button>
    <button class="nav-tab" onclick="switchTab('memory', this)">
      <span class="i18n-zh">🧠 記憶層</span><span class="i18n-en">🧠 Memory</span>
    </button>
    <button class="nav-tab" id="usersTabBtn" onclick="switchTab('users', this)" style="display:none">
      <span class="i18n-zh">👤 使用者</span><span class="i18n-en">👤 Users</span>
    </button>
  </div>
  <div class="nav-right">
    <span class="nav-time" id="lastUpdate"></span>
    <span class="i18n-badge" onclick="toggleLang()">ZH/EN</span>
    <button class="btn-icon" onclick="loadData()" title="Refresh">↻</button>
  </div>
</nav>

<!-- Task Creation Modal -->
<div class="modal-overlay" id="newTaskModal">
  <div class="modal" style="width:420px">
    <div class="modal-title">
      <span class="i18n-zh">➕ 新增任務</span>
      <span class="i18n-en">➕ New Task</span>
    </div>
    <div class="form-group">
      <label class="form-label"><span class="i18n-zh">標題</span><span class="i18n-en">Title</span></label>
      <input class="form-input" id="newTaskTitle" type="text" placeholder="Task title..." autocomplete="off">
    </div>
    <div class="form-group">
      <label class="form-label"><span class="i18n-zh">優先級</span><span class="i18n-en">Priority</span></label>
      <select class="form-select" id="newTaskPriority">
        <option value="P1">P1 — 緊急 / Urgent</option>
        <option value="P2" selected>P2 — 一般 / Normal</option>
        <option value="P3">P3 — 低優先 / Low</option>
      </select>
    </div>
    <div class="form-group">
      <label class="form-label"><span class="i18n-zh">分類</span><span class="i18n-en">Category</span></label>
      <select class="form-select" id="newTaskCategory">
        <option value="進行中">進行中 (In Progress)</option>
        <option value="待處理" selected>待處理 (Pending)</option>
      </select>
    </div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
      <div class="form-group" style="margin-bottom:0">
        <label class="form-label"><span class="i18n-zh">截止日期</span><span class="i18n-en">Due Date</span></label>
        <input class="form-input" id="newTaskDueDate" type="date">
      </div>
      <div class="form-group" style="margin-bottom:0">
        <label class="form-label"><span class="i18n-zh">負責人</span><span class="i18n-en">Assignee</span></label>
        <input class="form-input" id="newTaskAssignee" type="text" placeholder="@username">
      </div>
    </div>
    <div class="form-group">
      <label class="form-label">
        <span class="i18n-zh">任務描述 / 說明</span>
        <span class="i18n-en">Description</span>
      </label>
      <textarea class="form-input" id="newTaskDescription" rows="4" placeholder="任務描述或備註..." style="resize:vertical;font-family:inherit"></textarea>
    </div>
    <div class="modal-actions">
      <button class="btn-ghost" onclick="closeNewTaskModal()">
        <span class="i18n-zh">取消</span><span class="i18n-en">Cancel</span>
      </button>
      <button class="btn-primary" onclick="submitNewTask()">
        <span class="i18n-zh">建立任務</span><span class="i18n-en">Create Task</span>
      </button>
    </div>
  </div>
</div>

<!-- Tab: Tasks -->
<div class="tab-content active" id="tab-tasks">
  <div class="page tasks-layout">
    <!-- Stats Summary Bar (compact one-line) -->
    <div class="tasks-stats-row" id="statsCompact">
      <span class="stats-title"><span class="i18n-zh">📊 統計概要</span><span class="i18n-en">📊 Summary</span></span>
      <span class="stats-sep">|</span>
      <span class="stat-inline"><span class="stat-inline-label"><span class="i18n-zh">總任務</span><span class="i18n-en">Total</span></span> <span class="stat-inline-num" id="statTotal">—</span></span>
      <span class="stat-dot">·</span>
      <span class="stat-inline green"><span class="stat-inline-label"><span class="i18n-zh">已完成</span><span class="i18n-en">Done</span></span> <span class="stat-inline-num" id="statDone">—</span></span>
      <span class="stat-dot">·</span>
      <span class="stat-inline blue"><span class="stat-inline-label"><span class="i18n-zh">進行中</span><span class="i18n-en">Active</span></span> <span class="stat-inline-num" id="statInProgress">—</span></span>
      <span class="stat-dot">·</span>
      <span class="stat-inline amber"><span class="stat-inline-label"><span class="i18n-zh">待辦</span><span class="i18n-en">Pending</span></span> <span class="stat-inline-num" id="statPending">—</span></span>
      <span class="stat-dot">·</span>
      <span class="stat-inline rose"><span class="stat-inline-label"><span class="i18n-zh">阻塞</span><span class="i18n-en">Blocked</span></span> <span class="stat-inline-num" id="statBlocked">—</span></span>
      <span class="stat-dot">·</span>
      <span class="stat-inline purple"><span class="stat-inline-label"><span class="i18n-zh">完成率</span><span class="i18n-en">Rate</span></span> <span class="stat-inline-num" id="statRate">—</span></span>
      <span style="flex:1"></span>
      <button class="btn-primary" id="newTaskBtn" onclick="openNewTaskModal()" style="display:none;font-size:11px;padding:4px 10px">
        <span class="i18n-zh">➕ 新增</span>
        <span class="i18n-en">➕ New</span>
      </button>
    </div>

    <!-- Three Equal Panels -->
    <div class="tasks-panels" id="tasksThreePanel">
      <!-- Left Panel: Filter buttons + Main Task List -->
      <div>
        <div class="panel-header" style="display:flex;align-items:center;gap:4px;flex-wrap:wrap;padding:6px 8px" id="filterBar">
          <button class="filter-btn active" onclick="filterTasks('all', this)" style="padding:3px 8px;font-size:10px;border-radius:10px"><span class="i18n-zh">全部</span><span class="i18n-en">All</span></button>
          <button class="filter-btn" onclick="filterTasks('in_progress', this)" style="padding:3px 8px;font-size:10px;border-radius:10px"><span class="i18n-zh">進行中</span><span class="i18n-en">Active</span></button>
          <button class="filter-btn" onclick="filterTasks('done', this)" style="padding:3px 8px;font-size:10px;border-radius:10px"><span class="i18n-zh">已完成</span><span class="i18n-en">Done</span></button>
          <button class="filter-btn" onclick="filterTasks('pending', this)" style="padding:3px 8px;font-size:10px;border-radius:10px"><span class="i18n-zh">待辦</span><span class="i18n-en">Todo</span></button>
          <button class="filter-btn" onclick="filterTasks('overdue', this)" style="padding:3px 8px;font-size:10px;border-radius:10px"><span class="i18n-zh">已延誤</span><span class="i18n-en">Late</span></button>
          <button class="filter-btn" onclick="filterTasks('blocked', this)" style="padding:3px 8px;font-size:10px;border-radius:10px"><span class="i18n-zh">阻塞</span><span class="i18n-en">Block</span></button>
        </div>
        <div id="taskList">
          <!-- Compact task cards injected here -->
        </div>
      </div>

      <!-- Middle Panel: Subtask List -->
      <div>
        <div class="panel-header" id="taskMidHeader">
          <span class="i18n-zh">子任務</span><span class="i18n-en">Subtasks</span>
        </div>
        <div id="taskMidContent">
          <div class="panel-empty"><div>📝</div><span class="i18n-zh">← 點擊左側任務</span><span class="i18n-en">← Select a task</span></div>
        </div>
      </div>

      <!-- Right Panel: Info (3 sections) -->
      <div>
        <div class="panel-header" id="taskRightHeader">
          <span class="i18n-zh">任務詳情</span><span class="i18n-en">Task Detail</span>
        </div>
        <div id="taskRightContent">
          <div class="panel-empty"><div>📋</div><span class="i18n-zh">選擇任務查看詳情</span><span class="i18n-en">Select a task</span></div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- Tab: Memory -->
<div class="tab-content" id="tab-memory">
  <div class="page memory-page">
    <!-- Memory Stats Summary Row -->
    <div class="stats-row" id="memStatsRow" style="margin-bottom:12px">
      <div class="stat-card blue"><div class="stat-num" id="memStatLayers">6</div><div class="stat-label"><span class="i18n-zh">記憶層</span><span class="i18n-en">Layers</span></div></div>
      <div class="stat-card green"><div class="stat-num" id="memStatHealthy">—</div><div class="stat-label"><span class="i18n-zh">健康</span><span class="i18n-en">Healthy</span></div></div>
      <div class="stat-card rose"><div class="stat-num" id="memStatIssues">—</div><div class="stat-label"><span class="i18n-zh">異常</span><span class="i18n-en">Issues</span></div></div>
      <div class="stat-card blue"><div class="stat-num" id="memStatContainers">4</div><div class="stat-label"><span class="i18n-zh">NAS 容器</span><span class="i18n-en">Containers</span></div></div>
      <div class="stat-card amber"><div class="stat-num" id="memStatLatency">—</div><div class="stat-label"><span class="i18n-zh">搜尋延遲</span><span class="i18n-en">Avg Latency</span></div></div>
      <div class="stat-card purple"><div class="stat-num" id="memStatInjection">—</div><div class="stat-label"><span class="i18n-zh">注入總量</span><span class="i18n-en">Injection</span></div></div>
    </div>
    <div class="memory-panels">
      <!-- Left: Layer list -->
      <div class="mem-left-panel">
        <div class="mem-panel-header">
          <span class="i18n-zh">記憶層</span><span class="i18n-en">Layers</span>
        </div>
        <div id="memLayerList"><!-- injected --></div>
      </div>
      <!-- Middle: Files/Outline -->
      <div class="mem-mid-panel">
        <div class="mem-panel-header" id="memMidHeader">
          <span class="i18n-zh">選擇層以查看詳情</span><span class="i18n-en">Select a layer</span>
        </div>
        <div id="memMidContent">
          <div class="mem-panel-empty"><div>📂</div><span class="i18n-zh">點擊左側層查看</span><span class="i18n-en">Click a layer to view</span></div>
        </div>
      </div>
      <!-- Right: Detail -->
      <div class="mem-right-panel">
        <div class="mem-panel-header" id="memRightHeader">
          <span class="i18n-zh">詳細資訊</span><span class="i18n-en">Detail</span>
        </div>
        <div id="memRightContent">
          <div class="mem-panel-empty"><div>🔍</div><span class="i18n-zh">選擇項目查看詳情</span><span class="i18n-en">Select an item</span></div>
        </div>
      </div>
    </div>

    <!-- Latency Comparison Chart -->
    <div class="latency-chart-section" id="latencyChartSection" style="display:none">
      <div class="latency-chart-title"><span class="i18n-zh">搜索延遲比較</span><span class="i18n-en">Search Latency Comparison</span></div>
      <div class="latency-chart" id="latencyChart">
        <!-- bars injected by JS -->
      </div>
    </div>

    <!-- System Cards Row -->
    <div class="sys-cards-row" id="sysCardsRow" style="display:none">
      <!-- injected by JS -->
    </div>

  </div>
</div>

<!-- Tab: Users -->
<div class="tab-content" id="tab-users">
  <div class="page">
    <div class="users-header">
      <div class="users-title">
        <span class="i18n-zh">👤 使用者管理</span>
        <span class="i18n-en">👤 User Management</span>
      </div>
      <button class="btn-primary" onclick="openAddUser()">
        <span class="i18n-zh">+ 新增使用者</span>
        <span class="i18n-en">+ Add User</span>
      </button>
    </div>
    <div class="cf-access-note">
      <span class="note-icon">🔒</span>
      <span>
        <span class="i18n-zh">此儀表板受 <b>Cloudflare Access</b> 保護。使用者透過電子郵件驗證登入，無需密碼。</span>
        <span class="i18n-en">This dashboard is protected by <b>Cloudflare Access</b>. Users login via email verification — no password required.</span>
      </span>
    </div>
    <div class="card">
      <table class="users-table">
        <thead>
          <tr>
            <th><span class="i18n-zh">電子郵件</span><span class="i18n-en">Email</span></th>
            <th><span class="i18n-zh">角色</span><span class="i18n-en">Role</span></th>
            <th><span class="i18n-zh">加入日期</span><span class="i18n-en">Added Date</span></th>
            <th><span class="i18n-zh">操作</span><span class="i18n-en">Actions</span></th>
          </tr>
        </thead>
        <tbody id="usersTableBody">
        </tbody>
      </table>
    </div>
  </div>
</div>

<!-- Add User Modal -->
<div class="modal-overlay" id="userModal">
  <div class="modal">
    <div class="modal-title" id="userModalTitle">
      <span class="i18n-zh">新增使用者</span>
      <span class="i18n-en">Add User</span>
    </div>
    <div class="form-group">
      <label class="form-label"><span class="i18n-zh">電子郵件</span><span class="i18n-en">Email</span></label>
      <input class="form-input" id="newEmail" type="email" placeholder="user@example.com" autocomplete="off">
    </div>
    <div class="form-group">
      <label class="form-label"><span class="i18n-zh">角色</span><span class="i18n-en">Role</span></label>
      <select class="form-select" id="newRole" onchange="updateRoleDesc(this.value)">
        <option value="admin">admin — Full access (manage users, tasks, view all)</option>
        <option value="task_manager">task_manager — Manage tasks + view memory</option>
        <option value="viewer" selected>viewer — Read-only</option>
      </select>
      <div id="roleDescBox" style="margin-top:6px;font-size:11px;color:#a5b4fc;background:rgba(99,102,241,.08);border:1px solid rgba(99,102,241,.2);border-radius:6px;padding:6px 10px;line-height:1.5;display:none"></div>
    </div>
    <div style="background:rgba(99,102,241,.08);border:1px solid rgba(99,102,241,.2);border-radius:8px;padding:10px 12px;font-size:11px;color:#a5b4fc;margin-bottom:4px;line-height:1.5;">
      🔒 <span class="i18n-zh">使用者將透過 Cloudflare Access 電子郵件驗證登入</span><span class="i18n-en">User will login via Cloudflare Access email verification</span>
    </div>
    <div class="modal-actions">
      <button class="btn-ghost" onclick="closeModal()">
        <span class="i18n-zh">取消</span><span class="i18n-en">Cancel</span>
      </button>
      <button class="btn-primary" onclick="submitUserModal()">
        <span id="userModalSubmitLabel"><span class="i18n-zh">新增</span><span class="i18n-en">Add</span></span>
      </button>
    </div>
  </div>
</div>

<!-- Edit Role Modal -->
<div class="modal-overlay" id="editRoleModal">
  <div class="modal">
    <div class="modal-title">
      <span class="i18n-zh">變更角色</span>
      <span class="i18n-en">Change Role</span>
    </div>
    <div style="font-size:13px;color:var(--muted);margin-bottom:14px" id="editRoleEmail"></div>
    <div class="form-group">
      <label class="form-label"><span class="i18n-zh">角色</span><span class="i18n-en">Role</span></label>
      <select class="form-select" id="editRoleSelect">
        <option value="admin">admin — Full access (manage users, tasks, view all)</option>
        <option value="task_manager">task_manager — Manage tasks + view memory</option>
        <option value="viewer">viewer — Read-only</option>
      </select>
    </div>
    <div class="modal-actions">
      <button class="btn-ghost" onclick="closeEditRoleModal()">
        <span class="i18n-zh">取消</span><span class="i18n-en">Cancel</span>
      </button>
      <button class="btn-primary" onclick="saveEditRole()">
        <span class="i18n-zh">儲存</span><span class="i18n-en">Save</span>
      </button>
    </div>
  </div>
</div>

<!-- Floating refresh button -->
<button class="fab" onclick="loadData()" id="fabBtn" title="Refresh">↻</button>

<script>
// ─── State ───
let appData = null;
let selectedTaskId = null;
let currentLang = 'zh';
let isAdmin = true;
let currentFilter = 'all';

// ─── i18n ───
function toggleLang() {
  currentLang = currentLang === 'zh' ? 'en' : 'zh';
  document.body.setAttribute('data-lang', currentLang);
}

// ─── Tab switching ───
function switchTab(name, btn) {
  document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.nav-tab').forEach(t => t.classList.remove('active'));
  document.getElementById('tab-' + name).classList.add('active');
  btn.classList.add('active');
}

// ─── Data loading ───
async function loadData() {
  const fab = document.getElementById('fabBtn');
  fab.style.opacity = '0.5';
  fab.textContent = '⏳';

  try {
    const resp = await fetch('/api/data', { cache: 'no-store' });
    if (!resp.ok) throw new Error('HTTP ' + resp.status);
    appData = await resp.json();
  } catch(e) {
    if (window.__INITIAL_DATA__) {
      appData = window.__INITIAL_DATA__;
    } else {
      showError(e.message);
      fab.style.opacity = '1';
      fab.textContent = '↻';
      return;
    }
  }

  renderAll();
  fab.style.opacity = '1';
  fab.textContent = '↻';
  document.getElementById('loadingOverlay').style.display = 'none';
}

function showError(msg) {
  document.getElementById('loadingOverlay').style.display = 'none';
  const el = document.createElement('div');
  el.className = 'error-banner fade-in';
  el.innerHTML = `<div style="font-size:24px;margin-bottom:8px">⚠️</div>
    <div><b>API Unreachable</b></div>
    <div style="font-size:12px;margin-top:4px;color:#f87171">${msg}</div>
    <div style="font-size:12px;margin-top:8px;color:#94a3b8">Showing cached data if available</div>`;
  const tasksPage = document.getElementById('tab-tasks');
  if (tasksPage) tasksPage.querySelector('.page').prepend(el);
}

// ─── Render all ───
function renderAll() {
  if (!appData) return;
  const m = appData.memory || {};
  const ts = m.timestamp || new Date().toLocaleString('zh-TW');
  document.getElementById('lastUpdate').textContent = ts;

  renderStats(appData.tasks || []);
  renderFilters(appData.tasks || []);
  renderTasks(appData.tasks || [], appData.progress || []);
  renderMemory(m);
  renderUsers(appData.users || []);

  if (isAdmin) {
    document.getElementById('usersTabBtn').style.display = '';
    document.getElementById('newTaskBtn').style.display = '';
  }
}

// ─── Stats ───
function renderStats(tasks) {
  const total = tasks.length;
  const done = tasks.filter(t => t.status === 'done').length;
  const inProgress = tasks.filter(t => t.status === 'in_progress').length;
  const pending = tasks.filter(t => t.status === 'pending').length;
  const blocked = tasks.filter(t => t.status === 'blocked').length;
  const completionRate = total > 0 ? Math.round(done / total * 100) : 0;

  const set = (id, val) => { const el = document.getElementById(id); if (el) el.textContent = val; };
  set('statTotal', total);
  set('statDone', done);
  set('statInProgress', inProgress);
  set('statPending', pending);
  set('statBlocked', blocked);
  set('statRate', completionRate + '%');
}

// ─── Filters ───
function renderFilters(tasks) {
  // Filter bar is static HTML; just sync active state
  document.querySelectorAll('#filterBar .filter-btn').forEach(btn => {
    const onclick = btn.getAttribute('onclick') || '';
    const m = onclick.match(/filterTasks\('([^']+)'/);
    if (m) btn.classList.toggle('active', m[1] === currentFilter);
  });
}

function filterTasks(filterId, btn) {
  currentFilter = filterId;
  renderFilters(appData ? appData.tasks || [] : []);
  renderTasks(appData ? appData.tasks || [] : [], appData ? appData.progress || [] : []);
}

function setFilter(filterId) {
  filterTasks(filterId);
}

// ─── Tasks ───
let allFilteredTasks = [];
let allProgress = [];

function renderTasks(tasks, progress) {
  allProgress = progress;
  const listEl = document.getElementById('taskList');
  listEl.innerHTML = '';

  // Filter tasks
  let filtered = tasks;
  if (currentFilter !== 'all') {
    if (currentFilter === 'overdue') {
      filtered = tasks.filter(t => t.isOverdue);
    } else {
      filtered = tasks.filter(t => t.status === currentFilter);
    }
  }
  allFilteredTasks = filtered;

  if (!filtered.length) {
    listEl.innerHTML = '<div style="color:var(--muted);text-align:center;padding:40px 0">No tasks found</div>';
    return;
  }

  filtered.forEach((task, idx) => {
    const done = task.subtasks.filter(s => s.done).length;
    const total = task.subtasks.length;
    const pct = total > 0 ? Math.round(done / total * 100) : (task.status === 'done' ? 100 : 0);
    const statusClass = task.status || 'pending';
    const progressCls = statusClass === 'done' ? 'progress-green' : statusClass === 'in_progress' ? 'progress-blue' : 'progress-amber';
    const isSelected = task.id === selectedTaskId;

    const card = document.createElement('div');
    card.className = `task-card-compact status-${statusClass} fade-in${isSelected ? ' selected' : ''}`;
    card.style.animationDelay = (idx * 0.03) + 's';
    card.dataset.taskId = task.id;
    const dateParts = [];
    if (task.createdDate) dateParts.push('📅' + task.createdDate);
    if (task.dueDate) dateParts.push('⏰' + task.dueDate);
    if (task.assignee) dateParts.push('👤' + task.assignee);
    card.innerHTML = `
      <div class="tc-row1">
        <span class="badge badge-${task.priority?.toLowerCase() || 'p3'}" style="font-size:9px;padding:1px 5px">${task.priority || 'P3'}</span>
        <span class="tc-title">${task.title}</span>
      </div>
      ${dateParts.length > 0 ? '<div class="tc-row2">' + dateParts.join(' <span style="opacity:.4">|</span> ') + '</div>' : ''}
      <div class="tc-row2" style="margin-top:3px">
        ${statusBadgeMini(task.status)}
        ${total > 0 ? '<span style="flex:1"><div class="progress-wrap" style="margin:0"><div class="progress-fill ' + progressCls + '" style="width:' + pct + '%"></div></div></span><span style="font-size:9px;color:var(--muted)">' + done + '/' + total + '</span>' : ''}
      </div>
    `;
    card.onclick = () => selectTask(task, progress);
    listEl.appendChild(card);
  });
}

function statusBadgeMini(status) {
  const map = {
    done: ['badge-ok', '✓'],
    in_progress: ['badge-warn', '⚡'],
    pending: ['badge-p3', '⏳'],
    blocked: ['badge-err', '🚫'],
  };
  const [cls, icon] = map[status] || map.pending;
  return '<span class="badge ' + cls + '" style="font-size:9px;padding:1px 4px">' + icon + '</span>';
}

function statusBadge(status) {
  const map = {
    done: ['badge-ok', '✓ Done', '✓ 完成'],
    in_progress: ['badge-warn', '⚡ In Progress', '⚡ 進行中'],
    pending: ['badge-p3', '⏳ Pending', '⏳ 待辦'],
    blocked: ['badge-err', '🚫 Blocked', '🚫 阻塞'],
  };
  const [cls, en, zh] = map[status] || map.pending;
  return `<span class="badge ${cls}"><span class="i18n-zh">${zh}</span><span class="i18n-en">${en}</span></span>`;
}

function selectTask(task, progress) {
  window._currentSelectedTask = task;
  window._currentProgress = progress || [];
  window._currentTaskSubtasks = task.subtasks || [];
  selectedTaskId = task.id;
  document.querySelectorAll('.task-card-compact').forEach(c => c.classList.remove('selected'));
  if (event && event.currentTarget) event.currentTarget.classList.add('selected');

  const done = task.subtasks.filter(s => s.done).length;
  const total = task.subtasks.length;
  const titleWords = task.title.toLowerCase().split(/[\s\/]+/).filter(w => w.length > 2);
  const related = (progress || allProgress).filter(e =>
    titleWords.some(w => e.title.toLowerCase().includes(w) || e.items.some(i => i.toLowerCase().includes(w)))
  ).slice(0, 8);

  // ── Middle Panel: Subtask List ──
  const midHeader = document.getElementById('taskMidHeader');
  const midContent = document.getElementById('taskMidContent');
  midHeader.innerHTML = `
    <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap">
      <span class="badge badge-${task.priority?.toLowerCase() || 'p3'}" style="font-size:9px">${task.priority}</span>
      <span style="font-size:11px;font-weight:600;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${task.title}</span>
      ${statusBadgeMini(task.status)}
    </div>
  `;

  if (total > 0) {
    midContent.innerHTML = `
      <div style="padding:6px 10px;border-bottom:1px solid var(--border)">
        <div class="subtask-filter" id="subtaskFilter" style="margin-bottom:0">
          <button class="subtask-filter-btn active" onclick="filterSubtasks('all',this)"><span class="i18n-zh">全部</span><span class="i18n-en">All</span> (${total})</button>
          <button class="subtask-filter-btn" onclick="filterSubtasks('done',this)"><span class="i18n-zh">已完成</span><span class="i18n-en">Done</span> (${done})</button>
          <button class="subtask-filter-btn" onclick="filterSubtasks('pending',this)"><span class="i18n-zh">未完成</span><span class="i18n-en">Todo</span> (${total - done})</button>
        </div>
      </div>
      <div id="subtaskList">
        ${task.subtasks.map((s,si) => {
          const created = task.createdDate || '—';
          const due = task.dueDate || '—';
          const assignee = s.assignee || task.assignee || '—';
          const statusIcon = s.done ? '✅已完成' : '⏳待辦';
          return `
          <div class="subtask-row${s.done ? ' done' : ''}" data-subtask-done="${s.done}" data-subtask-idx="${si}" onclick="selectSubtask(${si})" style="cursor:pointer">
            <span class="st-icon">${s.done ? '☑' : '☐'}</span>
            <div style="flex:1;min-width:0">
              <span class="st-text${s.done ? ' done-text' : ''}">${s.text}</span>
              <div class="st-meta">📅 ${created} | ⏰ ${due} | 👤 ${assignee} | ${statusIcon}</div>
            </div>
          </div>`;
        }).join('')}
      </div>
    `;
  } else {
    midContent.innerHTML = '<div class="panel-empty"><div>📝</div><span class="i18n-zh">此任務無子任務</span><span class="i18n-en">No subtasks</span></div>';
  }

  // ── Right Panel: 3 Sections ──
  const rightHeader = document.getElementById('taskRightHeader');
  const rightContent = document.getElementById('taskRightContent');
  rightHeader.innerHTML = '<span class="i18n-zh">任務詳情</span><span class="i18n-en">Task Detail</span>';

  const dotColors = ['pt-dot-blue', 'pt-dot-green', 'pt-dot-amber'];

  rightContent.innerHTML = `
    <!-- Section 1: 主任務描述 (or subtask info when clicked) -->
    <div class="right-section" id="rightDescSection">
      <div class="right-section-title" id="rightDescTitle"><span class="i18n-zh">📝 主任務描述</span><span class="i18n-en">📝 Description</span></div>
      <div id="rightDescContent" style="padding:12px 14px;font-size:12px;line-height:1.7;color:var(--text)">
        ${task.description ? task.description : '<span style="color:var(--muted)"><span class="i18n-zh">無描述</span><span class="i18n-en">No description</span></span>'}
      </div>
    </div>
    <!-- Section 2: 進度記錄 -->
    <div class="right-section" style="border-bottom:none">
      <div class="right-section-title"><span class="i18n-zh">📋 進度記錄</span><span class="i18n-en">📋 Progress</span></div>
      ${related.length > 0 ? `
        <div class="progress-timeline" style="border-top:none">
          ${related.map((e, i) => `
            <div class="pt-entry fade-in" style="animation-delay:${i*0.05}s">
              <div class="pt-line"></div>
              <div class="pt-dot ${dotColors[i % dotColors.length]}"></div>
              <div class="pt-body">
                <div class="pt-date">${e.date}</div>
                <div class="pt-title">${e.title}</div>
                ${e.items.length > 0 ? '<div class="pt-items">' + e.items.slice(0,3).map(it => '• ' + it).join('<br>') + '</div>' : ''}
              </div>
            </div>
          `).join('')}
        </div>
      ` : '<div style="padding:14px;color:var(--muted);font-size:12px;text-align:center"><span class="i18n-zh">暫無相關進度記錄</span><span class="i18n-en">No related progress entries</span></div>'}
    </div>
  `;

  // Store subtasks for right-panel subtask info
  window._currentTaskSubtasks = task.subtasks;
}

// ─── Select Subtask (show info in right panel) ───
function selectSubtask(idx) {
  const subtasks = window._currentTaskSubtasks || [];
  const task = window._currentSelectedTask || {};
  const progress = window._currentProgress || [];
  if (!subtasks[idx]) return;
  const s = subtasks[idx];

  document.querySelectorAll('#subtaskList .subtask-row').forEach(r => r.style.background = '');
  const rows = document.querySelectorAll('#subtaskList .subtask-row');
  if (rows[idx]) rows[idx].style.background = 'rgba(99,102,241,.12)';

  const descTitle = document.getElementById('rightDescTitle');
  const descContent = document.getElementById('rightDescContent');
  if (!descTitle || !descContent) return;

  // Section 1: Main task description
  var html = '<div style="border-bottom:1px solid rgba(255,255,255,.08);padding-bottom:10px;margin-bottom:10px">';
  html += '<div style="font-size:11px;color:#94a3b8;font-weight:600;margin-bottom:4px">📝 主任務描述</div>';
  html += '<div style="font-size:12px;color:#cbd5e1;line-height:1.5">' + (task.description||'無描述') + '</div></div>';

  // Section 2: Subtask detail
  html += '<div style="border-bottom:1px solid rgba(255,255,255,.08);padding-bottom:10px;margin-bottom:10px">';
  html += '<div style="font-size:11px;color:#94a3b8;font-weight:600;margin-bottom:6px">📋 子任務描述</div>';
  html += '<div style="display:flex;align-items:flex-start;gap:8px"><span style="font-size:16px">' + (s.done?'☑':'☐') + '</span><div>';
  html += '<div style="font-size:13px;font-weight:600;margin-bottom:4px">' + s.text + '</div>';
  html += '<div style="display:flex;gap:8px;flex-wrap:wrap;font-size:11px;color:#94a3b8">';
  html += '<span>📅 ' + (task.createdDate||'-') + '</span>';
  html += '<span>⏰ ' + (task.dueDate||'-') + '</span>';
  html += '<span>👤 ' + (task.assignee||'-') + '</span>';
  html += '<span class="badge ' + (s.done?'badge-ok':'badge-warn') + '" style="font-size:10px">' + (s.done?'✅已完成':'⏳待辦') + '</span>';
  html += '</div></div></div></div>';

  // Section 3: Progress timeline
  html += '<div><div style="font-size:11px;color:#94a3b8;font-weight:600;margin-bottom:6px">📋 進度記錄</div>';
  var kw = s.text.substring(0,15);
  var rel = progress.filter(function(p){ return p.title&&(p.title.includes(kw)||p.items&&p.items.some(function(i){return i.includes(kw)})); });
  if(rel.length===0) rel = progress.slice(-3);
  rel.forEach(function(p){
    var c = p.title.includes('完成')?'#22c55e':p.title.includes('開始')?'#3b82f6':'#f59e0b';
    html += '<div style="display:flex;gap:10px;margin-bottom:8px;font-size:11px">';
    html += '<div style="display:flex;flex-direction:column;align-items:center;min-width:12px"><div style="width:8px;height:8px;border-radius:50%;background:'+c+';flex-shrink:0"></div><div style="width:1px;flex:1;background:rgba(255,255,255,.08)"></div></div>';
    html += '<div><div style="font-weight:600">'+(p.timestamp||'')+'</div><div style="color:#94a3b8">'+(p.title||'')+'</div>';
    if(p.items) p.items.slice(0,3).forEach(function(it){ html += '<div style="color:#64748b;font-size:10px;margin-top:2px">• '+it+'</div>'; });
    html += '</div></div>';
  });
  html += '</div>';

  descTitle.innerHTML = '📝 任務詳情';
  descContent.innerHTML = html;
}

// ─── Subtask Filter ───
function filterSubtasks(type, btn) {
  document.querySelectorAll('#subtaskFilter .subtask-filter-btn').forEach(b => b.classList.remove('active'));
  if (btn) btn.classList.add('active');
  const items = document.querySelectorAll('#subtaskList .subtask-row');
  items.forEach(item => {
    const isDone = item.dataset.subtaskDone === 'true';
    if (type === 'all') item.style.display = '';
    else if (type === 'done') item.style.display = isDone ? '' : 'none';
    else item.style.display = isDone ? 'none' : '';
  });
}

// ─── Memory ───
let memData = null;
let selectedLayerKey = null;

function renderMemoryStats(m) {
  // Count healthy/issue layers
  const layerKeys = ['l0','l1','l2','l3','l2plus','l4'];
  let healthy = 0, issues = 0;
  layerKeys.forEach(k => {
    const d = m[k];
    if (d && d.status === 'ok') healthy++;
    else issues++;
  });

  const set = (id, val) => { const el = document.getElementById(id); if (el) el.textContent = val; };
  set('memStatLayers', '6');
  set('memStatHealthy', healthy);
  set('memStatIssues', issues);
  set('memStatContainers', '4');

  // Avg latency from L2+ and L4
  const l2pMs = m.l2plus?.search_latency_ms ?? -1;
  const l4Ms = m.l4?.search_latency_ms ?? -1;
  const latencies = [l2pMs, l4Ms].filter(v => v >= 0);
  const avgLatency = latencies.length > 0 ? Math.round(latencies.reduce((a,b)=>a+b,0) / latencies.length) : -1;
  set('memStatLatency', avgLatency >= 0 ? avgLatency + 'ms' : 'N/A');

  // Color latency card: amber if >500
  const latCard = document.getElementById('memStatLatency')?.closest('.stat-card');
  if (latCard && avgLatency > 500) {
    latCard.className = 'stat-card amber';
  } else if (latCard && avgLatency >= 0) {
    latCard.className = 'stat-card green';
  }

  // Total injection estimate (tokens)
  const l0Tok = Math.round((m.l0?.size_kb||0) * 0.25);
  const l1Tok = (m.l1?.summaries||0) * 120;
  const l2Tok = Math.round((m.l2?.db_size_mb||0) * 2000);
  const l3Tok = (m.l3?.documents||0) * 15;
  const l2pTok = 800;
  const l4Tok = 600;
  const totalTok = l0Tok + l1Tok + l2Tok + l3Tok + l2pTok + l4Tok;
  const tokStr = totalTok > 1000 ? Math.round(totalTok/1000) + 'K' : totalTok.toString();
  set('memStatInjection', tokStr);
}

function renderMemory(m) {
  memData = m;
  selectedLayerKey = null;

  // Render stats row
  renderMemoryStats(m);

  const layers = [
    { key: 'l0', label: 'L0', name: { zh: 'Markdown 文件', en: 'Markdown Files' } },
    { key: 'l1', label: 'L1', name: { zh: 'lossless-claw', en: 'lossless-claw' } },
    { key: 'l2', label: 'L2', name: { zh: 'LanceDB 向量', en: 'LanceDB Vector' } },
    { key: 'l3', label: 'L3', name: { zh: 'QMD BM25', en: 'QMD BM25' } },
    { key: 'l2plus', label: 'L2+', name: { zh: 'MemOS 知識圖譜', en: 'MemOS Graph' } },
    { key: 'l4', label: 'L4', name: { zh: 'Cognee 深度理解', en: 'Cognee Cognition' } },
    { key: 'system', label: '⚙', name: { zh: '系統', en: 'System' } },
  ];

  const listEl = document.getElementById('memLayerList');
  listEl.innerHTML = '';
  layers.forEach((layer, idx) => {
    const data = layer.key === 'system' ? { status: (m.gateway?.status || 'ok') } : (m[layer.key] || {});
    const status = data.status || 'warn';
    const dotCls = status === 'ok' ? 'dot-ok' : status === 'warn' ? 'dot-warn' : 'dot-err';
    // Compute injection estimate for badge
    let injectPct = 0;
    if (layer.key === 'l0') injectPct = Math.min(100, Math.round((m.l0?.size_kb||0)*0.25/50000*100));
    else if (layer.key === 'l1') injectPct = Math.min(100, Math.round((m.l1?.summaries||0)*120/100000*100));
    else if (layer.key === 'l2') injectPct = Math.min(100, Math.round((m.l2?.db_size_mb||0)*2/8000*100));
    else if (layer.key === 'l3') injectPct = Math.min(100, Math.round((m.l3?.documents||0)*15/5000*100));
    else if (layer.key === 'l2plus') injectPct = Math.min(100, Math.round(800/10000*100));
    else if (layer.key === 'l4') injectPct = Math.min(100, Math.round(600/8000*100));
    const injectFillCls = injectPct > 75 ? 'inject-hot' : injectPct > 40 ? 'inject-warn' : 'inject-ok';

    const item = document.createElement('div');
    item.className = 'mem-layer-item fade-in';
    item.style.animationDelay = (idx * 0.05) + 's';
    item.dataset.key = layer.key;
    item.innerHTML = `
      <span class="badge badge-layer" style="font-size:10px;padding:1px 6px">${layer.label}</span>
      <div style="flex:1;min-width:0">
        <div class="mem-layer-name"><span class="i18n-zh">${layer.name.zh}</span><span class="i18n-en">${layer.name.en}</span></div>
        ${layer.key !== 'system' ? `<div class="inject-bar" style="margin-top:3px"><div class="inject-fill ${injectFillCls}" style="width:${injectPct}%"></div></div>` : ''}
      </div>
      <span class="status-dot ${dotCls}"></span>
    `;
    item.onclick = () => selectMemLayer(layer.key);
    listEl.appendChild(item);
  });

  // Render latency comparison chart
  renderLatencyChart(m);
  // Render system cards
  renderSysCards(m);
}

// ─── Latency Chart ───
function renderLatencyChart(m) {
  const section = document.getElementById('latencyChartSection');
  const chart = document.getElementById('latencyChart');
  if (!section || !chart) return;

  const l2plusMs = m.l2plus?.search_latency_ms ?? -1;
  const l4Ms = m.l4?.search_latency_ms ?? -1;

  if (l2plusMs < 0 && l4Ms < 0) { section.style.display = 'none'; return; }
  section.style.display = '';

  const bars = [
    { label: 'L2+ MemOS', ms: l2plusMs, color: l2plusMs < 500 ? 'lc-bar-ok' : l2plusMs < 1500 ? 'lc-bar-warn' : 'lc-bar-err' },
    { label: 'L4 Cognee', ms: l4Ms,     color: l4Ms < 500 ? 'lc-bar-ok' : l4Ms < 1500 ? 'lc-bar-warn' : 'lc-bar-err' },
  ];
  const maxMs = Math.max(1, ...bars.map(b => b.ms).filter(v => v >= 0));
  chart.innerHTML = bars.map(b => {
    if (b.ms < 0) return `<div class="lc-bar-wrap"><div class="lc-val" style="color:var(--muted)">N/A</div><div class="lc-bar ${b.color}" style="height:4px"></div><div class="lc-label">${b.label}</div></div>`;
    const h = Math.max(4, Math.round(b.ms / maxMs * 100));
    return `<div class="lc-bar-wrap"><div class="lc-val">${b.ms}ms</div><div class="lc-bar ${b.color}" style="height:${h}%"></div><div class="lc-label">${b.label}</div></div>`;
  }).join('');
}

// ─── System Cards ───
function modelBadgeCls(model) {
  if (!model || model === 'unknown' || model === '—') return 'badge-layer';
  const m = model.toLowerCase();
  if (m.includes('claude') || m.includes('anthropic')) return 'badge-anthropic';
  if (m.includes('minimax') || m.includes('m2')) return 'badge-minimax';
  if (m.includes('gpt') || m.includes('openai')) return 'badge-openai';
  return 'badge-layer';
}

function renderSysCards(m) {
  const row = document.getElementById('sysCardsRow');
  if (!row) return;
  const gw = m.gateway || {};
  const disk = m.disk || {};
  const rootPct  = parseInt(disk.root  || '0') || 0;
  const usersPct = parseInt(disk.users || '0') || 0;
  const rootCls  = rootPct  > 85 ? 'disk-err' : rootPct  > 70 ? 'disk-warn' : 'disk-ok';
  const usersCls = usersPct > 85 ? 'disk-err' : usersPct > 70 ? 'disk-warn' : 'disk-ok';
  const gwColor  = gw.status === 'ok' ? 'var(--green)' : 'var(--amber)';
  const nasOk    = m.l2plus?.status === 'ok' && m.l4?.status === 'ok';
  const nasColor = nasOk ? 'var(--green)' : 'var(--rose)';

  row.style.display = '';
  row.innerHTML = `
    <div class="sys-mini-card">
      <div class="sys-mini-title">🌐 Gateway</div>
      <div class="sys-mini-val" style="color:${gwColor}">${gw.status === 'ok' ? '✓ OK' : '⚠ Warn'}</div>
      <div class="sys-mini-status" style="color:var(--muted)">${gw.critical_issues ?? 0} issues</div>
    </div>
    <div class="sys-mini-card">
      <div class="sys-mini-title">💾 Disk /</div>
      <div class="sys-mini-val">${disk.root || '—'}</div>
      <div class="sys-disk-track"><div class="sys-disk-fill ${rootCls}" style="width:${rootPct}%"></div></div>
    </div>
    <div class="sys-mini-card">
      <div class="sys-mini-title">🏠 Disk /Users</div>
      <div class="sys-mini-val">${disk.users || '—'}</div>
      <div class="sys-disk-track"><div class="sys-disk-fill ${usersCls}" style="width:${usersPct}%"></div></div>
    </div>
    <div class="sys-mini-card">
      <div class="sys-mini-title">🐳 NAS Docker</div>
      <div class="sys-mini-val" style="color:${nasColor}">${nasOk ? '✓ Running' : '⚠ Partial'}</div>
      <div class="sys-mini-status" style="color:var(--muted)">memos·cognee·neo4j·qdrant</div>
    </div>
  `;
}

function selectMemLayer(key) {
  selectedLayerKey = key;
  document.querySelectorAll('.mem-layer-item').forEach(el => {
    el.classList.toggle('selected', el.dataset.key === key);
  });
  renderMemMid(key);
  document.getElementById('memRightContent').innerHTML =
    '<div class="mem-panel-empty"><div>🔍</div><span class="i18n-zh">選擇項目查看詳情</span><span class="i18n-en">Select an item</span></div>';
}

function injectBar(pct, label) {
  const fillCls = pct > 75 ? 'inject-hot' : pct > 40 ? 'inject-warn' : 'inject-ok';
  return `<div class="inject-meta"><span>${label}</span><span>${pct}%</span></div>
    <div class="inject-bar"><div class="inject-fill ${fillCls}" style="width:${pct}%"></div></div>`;
}

function latencyGauge(ms) {
  if (ms < 0) return '';
  const pct = Math.min(100, Math.round(ms / 20));
  const cls = ms < 500 ? 'gauge-ok' : ms < 1500 ? 'gauge-warn' : 'gauge-err';
  return `<div class="latency-gauge" style="margin:8px 0">
    <span style="font-size:13px;font-weight:700">${ms}ms</span>
    <div class="gauge-bar-wrap"><div class="gauge-bar-fill ${cls}" style="width:${pct}%"></div></div>
  </div>`;
}

function renderMemMid(key) {
  const m = memData || {};
  const midEl = document.getElementById('memMidContent');
  const hdrEl = document.getElementById('memMidHeader');
  midEl.innerHTML = '';

  const mkItem = (icon, name, meta, extra) => {
    const el = document.createElement('div');
    el.className = 'mem-mid-item fade-in';
    el.innerHTML = `<span style="font-size:14px;flex-shrink:0">${icon}</span>
      <div style="flex:1;min-width:0">
        <div class="mem-mid-item-name">${name}</div>
        ${extra || ''}
      </div>
      ${meta ? `<span class="mem-mid-item-meta">${meta}</span>` : ''}`;
    midEl.appendChild(el);
    return el;
  };

  if (key === 'l0') {
    hdrEl.innerHTML = '<span class="i18n-zh">工作區 MD 文件</span><span class="i18n-en">Workspace MD Files</span>';
    const d = m.l0 || {};
    const iPct = Math.min(100, Math.round((d.size_kb||0)*0.25/50000*100));
    // Summary item with injection bar
    const sumEl = mkItem('📊', `${d.files||0} files · ${d.size_kb||0} KB`, d.status||'?',
      injectBar(iPct, 'Token injection estimate'));
    sumEl.onclick = () => renderDetailKV('L0 Markdown', [
      {k:'Files', v:d.files}, {k:'Size', v:(d.size_kb||0)+' KB'}, {k:'Status', v:d.status}
    ]);
    const names = d.names || [];
    names.forEach((name, i) => {
      const el = mkItem('📄', name, '', '');
      el.onclick = () => renderDetailL0File(name);
    });

  } else if (key === 'l1') {
    hdrEl.innerHTML = '<span class="i18n-zh">lossless-claw</span><span class="i18n-en">lossless-claw</span>';
    const d = m.l1 || {};
    const iPct = Math.min(100, Math.round((d.summaries||0)*120/100000*100));
    const mdlCls = modelBadgeCls(d.model);
    mkItem('📊', `${d.summaries||0} summaries`, '', injectBar(iPct, 'Token injection') +
      `<div style="margin-top:6px"><span class="badge ${mdlCls}" style="font-size:10px">${shortModel(d.model)}</span></div>`)
    .onclick = () => renderDetailKV('lossless-claw', [
      {k:'Summaries',v:d.summaries},{k:'Model',v:d.model},{k:'DB Size',v:(d.db_size_kb||0)+' KB'},{k:'Status',v:d.status}
    ]);
    mkItem('💾', 'SQLite DB', (d.db_size_kb||0)+' KB', '').onclick = () => renderDetailKV('lossless-claw DB', [
      {k:'DB Path',v:'~/.openclaw/lcm.db'},{k:'Size',v:(d.db_size_kb||0)+' KB'}
    ]);

  } else if (key === 'l2') {
    hdrEl.innerHTML = '<span class="i18n-zh">LanceDB 配置</span><span class="i18n-en">LanceDB Config</span>';
    const d = m.l2 || {};
    const iPct = Math.min(100, Math.round((d.db_size_mb||0)*2/8000*100));
    mkItem('🗄', `${d.lance_files||0} lance files · ${d.db_size_mb||0} MB`, '', injectBar(iPct, 'Vector tokens estimate'))
    .onclick = () => renderDetailKV('LanceDB Pro', [
      {k:'Lance Files',v:d.lance_files},{k:'DB Size',v:(d.db_size_mb||0)+' MB'},
      {k:'Embedding',v:d.embedding_model},{k:'Rerank',v:d.rerank||'none'},
      {k:'Half-life',v:(d.halflife_days||'?')+' days'},{k:'Status',v:d.status}
    ]);
    mkItem('🧬', 'Embedding Model', shortModel(d.embedding_model), '').onclick = () => {};
    mkItem('🔃', 'Rerank', d.rerank||'none', '').onclick = () => {};

  } else if (key === 'l3') {
    hdrEl.innerHTML = '<span class="i18n-zh">QMD BM25</span><span class="i18n-en">QMD BM25</span>';
    const d = m.l3 || {};
    const iPct = Math.min(100, Math.round((d.documents||0)*15/5000*100));
    mkItem('📚', `${d.documents||0} documents`, d.engine||'BM25', injectBar(iPct, 'BM25 index tokens'))
    .onclick = () => renderDetailKV('QMD BM25', [{k:'Documents',v:d.documents},{k:'Engine',v:d.engine||'BM25'},{k:'Status',v:d.status}]);

  } else if (key === 'l2plus') {
    hdrEl.innerHTML = '<span class="i18n-zh">MemOS 服務</span><span class="i18n-en">MemOS Services</span>';
    const d = m.l2plus || {};
    const iPct = Math.min(100, Math.round(800/10000*100));
    const mdlCls = modelBadgeCls(d.llm_model);
    mkItem('🌐', 'API', d.status==='ok'?'✓ Online':'✗ Offline',
      injectBar(iPct, 'Context injection') +
      `<div style="margin-top:6px"><span class="badge ${mdlCls}" style="font-size:10px">${shortModel(d.llm_model)}</span></div>` +
      latencyGauge(d.search_latency_ms >= 0 ? d.search_latency_ms : -1))
    .onclick = () => renderDetailL2plus(d);
    mkItem('🕸', 'Neo4j', d.neo4j||'—', '').onclick = () => renderDetailL2plus(d);
    mkItem('📐', 'Qdrant', d.qdrant||'—', '').onclick = () => renderDetailL2plus(d);

  } else if (key === 'l4') {
    hdrEl.innerHTML = '<span class="i18n-zh">Cognee 服務</span><span class="i18n-en">Cognee Services</span>';
    const d = m.l4 || {};
    const iPct = Math.min(100, Math.round(600/8000*100));
    const mdlCls = modelBadgeCls(d.llm_model);
    mkItem('🌐', 'API', d.status==='ok'?'✓ Online':'✗ Offline',
      injectBar(iPct, 'Context injection') +
      `<div style="margin-top:6px"><span class="badge ${mdlCls}" style="font-size:10px">${shortModel(d.llm_model)}</span></div>` +
      latencyGauge(d.search_latency_ms >= 0 ? d.search_latency_ms : -1))
    .onclick = () => renderDetailL4(d);

  } else if (key === 'system') {
    hdrEl.innerHTML = '<span class="i18n-zh">系統概覽</span><span class="i18n-en">System Overview</span>';
    const gw = m.gateway || {};
    const disk = m.disk || {};
    [
      { icon: '🌐', label: 'Gateway', value: gw.status === 'ok' ? '✓ OK' : '⚠ ' + gw.critical_issues + ' issues', fn: () => renderDetailSystem(m) },
      { icon: '💾', label: 'Disk /', value: disk.root || '—', fn: () => renderDetailSystem(m) },
      { icon: '🏠', label: 'Disk /Users', value: disk.users || '—', fn: () => renderDetailSystem(m) },
      { icon: '🐳', label: 'NAS Docker', value: (m.l2plus?.status==='ok'&&m.l4?.status==='ok')?'✓ Running':'⚠ Partial', fn: () => renderDetailSystem(m) },
    ].forEach(it => { mkItem(it.icon, it.label, it.value, '').onclick = it.fn; });
  }
}

// ─── Memory Detail Renderers ───
function shortModel(model) {
  if (!model || model === 'unknown' || model === '—') return '—';
  const m = model.replace('openai/', '');
  if (m.length > 24) return m.substring(0, 22) + '…';
  return m;
}

function renderDetailKV(title, kvPairs) {
  const el = document.getElementById('memRightContent');
  const hdr = document.getElementById('memRightHeader');
  hdr.textContent = title;
  el.innerHTML = `
    <div class="mem-detail-content">
      <div class="mem-detail-title">${title}</div>
      <div class="mem-kv-list">
        ${kvPairs.map(kv => `
          <div class="mem-kv-row">
            <span class="mem-kv-key">${kv.k}</span>
            <span class="mem-kv-val">${kv.v ?? '—'}</span>
          </div>
        `).join('')}
      </div>
    </div>
  `;
}

function renderDetailL0File(fname) {
  const el = document.getElementById('memRightContent');
  const hdr = document.getElementById('memRightHeader');
  hdr.textContent = fname;
  el.innerHTML = '<div class="mem-detail-content"><div class="mem-detail-title">' + fname + '</div><div style="color:var(--muted);font-size:12px">Loading...</div></div>';
  fetch('/api/memory/file?path=' + encodeURIComponent(fname))
    .then(r => r.json())
    .then(data => {
      el.innerHTML = `
        <div class="mem-detail-content">
          <div class="mem-detail-title">📄 ${data.name || fname}</div>
          <div class="mem-detail-meta">${data.truncated ? '(truncated to 2000 chars)' : 'Full content'}</div>
          <div class="mem-detail-preview">${(data.content || '').replace(/</g,'&lt;').replace(/>/g,'&gt;')}</div>
        </div>
      `;
    })
    .catch(e => {
      el.innerHTML = '<div class="mem-detail-content"><div style="color:var(--rose)">Error loading file: ' + e.message + '</div></div>';
    });
}

function renderDetailL2plus(d) {
  const el = document.getElementById('memRightContent');
  const hdr = document.getElementById('memRightHeader');
  hdr.textContent = 'MemOS Details';
  const mdlCls = modelBadgeCls(d.llm_model);
  el.innerHTML = `
    <div class="mem-detail-content">
      <div class="mem-detail-title">🌐 MemOS 知識圖譜</div>
      <div class="mem-kv-list">
        <div class="mem-kv-row"><span class="mem-kv-key">API Endpoint</span><span class="mem-kv-val">${d.api || '—'}</span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Status</span><span class="mem-kv-val"><span class="badge ${d.status==='ok'?'badge-ok':'badge-err'}">${d.status==='ok'?'✓ Online':'✗ Offline'}</span></span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Search Latency</span><span class="mem-kv-val">${d.search_latency_ms >= 0 ? d.search_latency_ms + 'ms' : 'N/A'}</span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">LLM Model</span><span class="mem-kv-val"><span class="badge ${mdlCls}" style="font-size:11px">${shortModel(d.llm_model)}</span></span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Neo4j</span><span class="mem-kv-val"><span class="badge ${d.neo4j==='ok'?'badge-ok':'badge-err'}">${d.neo4j||'—'}</span></span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Qdrant</span><span class="mem-kv-val"><span class="badge ${d.qdrant==='ok'?'badge-ok':'badge-err'}">${d.qdrant||'—'}</span></span></div>
      </div>
      ${d.search_latency_ms >= 0 ? latencyGauge(d.search_latency_ms) : ''}
    </div>
  `;
}

function renderDetailL4(d) {
  const el = document.getElementById('memRightContent');
  const hdr = document.getElementById('memRightHeader');
  hdr.textContent = 'Cognee Details';
  const mdlCls = modelBadgeCls(d.llm_model);
  el.innerHTML = `
    <div class="mem-detail-content">
      <div class="mem-detail-title">🧠 Cognee 深度理解</div>
      <div class="mem-kv-list">
        <div class="mem-kv-row"><span class="mem-kv-key">API Endpoint</span><span class="mem-kv-val">${d.api || '—'}</span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Status</span><span class="mem-kv-val"><span class="badge ${d.status==='ok'?'badge-ok':'badge-err'}">${d.status==='ok'?'✓ Online':'✗ Offline'}</span></span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Search Latency</span><span class="mem-kv-val">${d.search_latency_ms >= 0 ? d.search_latency_ms + 'ms' : 'N/A'}</span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">LLM Model</span><span class="mem-kv-val"><span class="badge ${mdlCls}" style="font-size:11px">${shortModel(d.llm_model)}</span></span></div>
      </div>
      ${d.search_latency_ms >= 0 ? latencyGauge(d.search_latency_ms) : ''}
    </div>
  `;
}

function renderDetailSystem(m) {
  const el = document.getElementById('memRightContent');
  const hdr = document.getElementById('memRightHeader');
  hdr.textContent = 'System Info';
  const gw = m.gateway || {};
  const disk = m.disk || {};
  const rootPct = parseInt(disk.root || '0') || 0;
  const usersPct = parseInt(disk.users || '0') || 0;
  el.innerHTML = `
    <div class="mem-detail-content">
      <div class="mem-detail-title">⚙ System Overview</div>
      <div class="mem-kv-list">
        <div class="mem-kv-row"><span class="mem-kv-key">Gateway</span><span class="mem-kv-val"><span class="badge ${gw.status==='ok'?'badge-ok':'badge-warn'}">${gw.status==='ok'?'✓ OK':'⚠ '+gw.critical_issues+' issues'}</span></span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Disk /</span><span class="mem-kv-val">${disk.root || '—'}</span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Disk /Users</span><span class="mem-kv-val">${disk.users || '—'}</span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Neo4j</span><span class="mem-kv-val"><span class="badge ${m.l2plus?.neo4j==='ok'?'badge-ok':'badge-err'}">${m.l2plus?.neo4j||'—'}</span></span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Qdrant</span><span class="mem-kv-val"><span class="badge ${m.l2plus?.qdrant==='ok'?'badge-ok':'badge-err'}">${m.l2plus?.qdrant||'—'}</span></span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">MemOS API</span><span class="mem-kv-val"><span class="badge ${m.l2plus?.status==='ok'?'badge-ok':'badge-err'}">${m.l2plus?.status||'—'}</span></span></div>
        <div class="mem-kv-row"><span class="mem-kv-key">Cognee API</span><span class="mem-kv-val"><span class="badge ${m.l4?.status==='ok'?'badge-ok':'badge-err'}">${m.l4?.status||'—'}</span></span></div>
      </div>
      <div style="margin-top:12px">
        <div style="font-size:11px;color:var(--muted);margin-bottom:4px">Disk / (${disk.root || '—'})</div>
        <div class="sys-disk-track"><div class="sys-disk-fill ${rootPct>85?'disk-err':rootPct>70?'disk-warn':'disk-ok'}" style="width:${rootPct}%"></div></div>
        <div style="font-size:11px;color:var(--muted);margin:8px 0 4px">Disk /Users (${disk.users || '—'})</div>
        <div class="sys-disk-track"><div class="sys-disk-fill ${usersPct>85?'disk-err':usersPct>70?'disk-warn':'disk-ok'}" style="width:${usersPct}%"></div></div>
      </div>
    </div>
  `;
}

// ─── Users ───
let editingUserEmail = null;

function renderUsers(users) {
  users = users.map(u => ({
    email: u.email || (u.username ? u.username + '@example.com' : ''),
    role: u.role === 'agent' ? 'viewer' : (u.role || 'viewer'),
    createdAt: u.createdAt || u.created || new Date().toISOString().split('T')[0],
  }));
  if (appData) appData.users = users;

  const tbody = document.getElementById('usersTableBody');
  tbody.innerHTML = '';
  users.forEach((u, idx) => {
    const roleBadgeCls = u.role === 'admin' ? 'badge-p1' : u.role === 'task_manager' ? 'badge-warn' : 'badge-p3';
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td><b>${u.email}</b></td>
      <td><span class="badge ${roleBadgeCls}">${u.role}</span></td>
      <td style="color:var(--muted)">${u.createdAt || '—'}</td>
      <td>
        <button class="btn-sm" onclick="openEditRole('${u.email}', '${u.role}')">Edit</button>
        <button class="btn-sm btn-sm-danger" onclick="deleteUser('${u.email}')" style="margin-left:4px">Delete</button>
      </td>
    `;
    tbody.appendChild(tr);
  });
}

function openAddUser() {
  editingUserEmail = null;
  document.getElementById('newEmail').value = '';
  document.getElementById('newRole').value = 'viewer';
  document.getElementById('userModal').classList.add('open');
  setTimeout(() => document.getElementById('newEmail').focus(), 100);
}

function closeModal() {
  document.getElementById('userModal').classList.remove('open');
}

function submitUserModal() {
  const email = document.getElementById('newEmail').value.trim();
  if (!email || !email.includes('@')) {
    document.getElementById('newEmail').style.borderColor = 'var(--rose)';
    setTimeout(() => { document.getElementById('newEmail').style.borderColor = ''; }, 2000);
    return;
  }
  if (!appData.users) appData.users = [];
  const existing = appData.users.findIndex(u => u.email === email);
  if (existing >= 0) {
    appData.users[existing].role = document.getElementById('newRole').value;
  } else {
    appData.users.push({ email, role: document.getElementById('newRole').value, createdAt: new Date().toISOString().split('T')[0] });
  }
  renderUsers(appData.users);
  closeModal();
}

function openEditRole(email, currentRole) {
  editingUserEmail = email;
  document.getElementById('editRoleEmail').textContent = email;
  document.getElementById('editRoleSelect').value = currentRole;
  document.getElementById('editRoleModal').classList.add('open');
}

function closeEditRoleModal() {
  document.getElementById('editRoleModal').classList.remove('open');
}

function saveEditRole() {
  if (!editingUserEmail || !appData.users) return;
  const idx = appData.users.findIndex(u => u.email === editingUserEmail);
  if (idx >= 0) appData.users[idx].role = document.getElementById('editRoleSelect').value;
  renderUsers(appData.users);
  closeEditRoleModal();
}

function deleteUser(email) {
  if (!confirm('Delete user: ' + email + '?')) return;
  if (appData.users) {
    appData.users = appData.users.filter(u => u.email !== email);
    renderUsers(appData.users);
  }
}

document.getElementById('userModal').addEventListener('click', function(e) {
  if (e.target === this) closeModal();
});

document.getElementById('editRoleModal').addEventListener('click', function(e) {
  if (e.target === this) closeEditRoleModal();
});

document.getElementById('newTaskModal').addEventListener('click', function(e) {
  if (e.target === this) closeNewTaskModal();
});

// ─── New Task Modal ───
function openNewTaskModal() {
  document.getElementById('newTaskTitle').value = '';
  document.getElementById('newTaskPriority').value = 'P2';
  document.getElementById('newTaskCategory').value = '待處理';
  document.getElementById('newTaskDueDate').value = '';
  document.getElementById('newTaskAssignee').value = '';
  document.getElementById('newTaskDescription').value = '';
  document.getElementById('newTaskModal').classList.add('open');
  setTimeout(() => document.getElementById('newTaskTitle').focus(), 100);
}

function closeNewTaskModal() {
  document.getElementById('newTaskModal').classList.remove('open');
}

function submitNewTask() {
  const title = document.getElementById('newTaskTitle').value.trim();
  const priority = document.getElementById('newTaskPriority').value;
  const category = document.getElementById('newTaskCategory').value;
  const dueDate = document.getElementById('newTaskDueDate').value;
  const assignee = document.getElementById('newTaskAssignee').value.trim();
  const description = document.getElementById('newTaskDescription').value.trim();

  if (!title) {
    document.getElementById('newTaskTitle').style.borderColor = 'var(--rose)';
    setTimeout(() => { document.getElementById('newTaskTitle').style.borderColor = ''; }, 2000);
    return;
  }

  const payload = { title, priority, category, subtasks: [], dueDate: dueDate || undefined, assignee: assignee || undefined, description: description || undefined };

  fetch('/api/tasks', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  })
  .then(r => {
    if (r.ok) {
      closeNewTaskModal();
      loadData();
    } else {
      addTaskLocally(payload);
    }
  })
  .catch(() => addTaskLocally(payload));
}

function addTaskLocally(payload) {
  if (!appData) appData = { tasks: [], progress: [], users: [] };
  if (!appData.tasks) appData.tasks = [];
  const statusMap = { '進行中': 'in_progress', '待處理': 'pending' };
  appData.tasks.unshift({
    id: Date.now(),
    title: payload.title,
    priority: payload.priority,
    status: statusMap[payload.category] || 'pending',
    category: payload.category,
    subtasks: [],
    description: payload.description || null,
    dueDate: payload.dueDate || null,
    assignee: payload.assignee || null,
    createdDate: new Date().toISOString().split('T')[0],
    isOverdue: false,
  });
  closeNewTaskModal();
  renderStats(appData.tasks);
  renderFilters(appData.tasks);
  renderTasks(appData.tasks, appData.progress || []);
}

function updateRoleDesc(role) {
  const box = document.getElementById('roleDescBox');
  if (!box) return;
  const descs = {
    admin: '👑 Full access: manage users, tasks, and view all memory layers.',
    task_manager: '🛠 Manage tasks + view memory layers.',
    viewer: '👁 Read-only access.',
  };
  if (descs[role]) { box.textContent = descs[role]; box.style.display = ''; }
  else { box.style.display = 'none'; }
}

// ─── Init ───
window.addEventListener('DOMContentLoaded', () => {
  loadData();
});
</script>

</body>
</html>"""

with open(outfile, 'w', encoding='utf-8') as f:
    f.write(html)

print(f"Generated: {outfile}")
HTMLEOF

echo "HTML generated: $OUTFILE"

echo ""
echo "✅ Unified Dashboard updated successfully!"
echo "   Output: $OUTFILE"
echo "   Time:   $NOW"

# ── Sync to serve directory ──
SERVE_DIR="$HOME/.openclaw/dashboard-serve"
mkdir -p "$SERVE_DIR"
cp "$OUTFILE" "$SERVE_DIR/unified-dashboard.html"
cp "$OUTFILE" "$SERVE_DIR/index.html"
echo "   Serve:  $SERVE_DIR/unified-dashboard.html"
