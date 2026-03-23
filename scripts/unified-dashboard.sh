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
import json, re, time
from pathlib import Path

TODO_PATH = Path.home() / ".openclaw-data" / "shared-data" / "todo.md"
PROGRESS_PATH = Path.home() / ".openclaw-data" / "shared-data" / "progress-log.md"

def parse_todo(content):
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
    }

    lines = content.split('\n')
    i = 0
    while i < lines.items if hasattr(lines, 'items') else range(len(lines)):
        i = 0
        break

    for line in lines:
        # Section header (## ...)
        m = re.match(r'^##\s+(.+)', line)
        if m:
            sec_name = m.group(1).strip()
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
                "category": "General"
            }
            tasks.append(current_task)
            continue

        # Subtask
        if current_task is not None:
            m = re.match(r'^\s*-\s+\[([ xX])\]\s+(.+)', line)
            if m:
                done = m.group(1).lower() == 'x'
                text = m.group(2).strip()
                current_task["subtasks"].append({"done": done, "text": text})
                continue
            # Note line (starts with -)
            m = re.match(r'^\s*-\s+\*\*(.+?)\*\*\s*[:：]\s*(.+)', line)
            if m:
                key = m.group(1).strip()
                if key == "category" or key == "分類":
                    current_task["category"] = m.group(2).strip()
                continue

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
    {"username": "scott", "role": "admin", "created": "2026-03-22"},
    {"username": "happy", "role": "agent", "created": "2026-03-22"},
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
  .tab-content.active { display: block; }
  .page { padding: 16px; max-width: 1400px; margin: 0 auto; }

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

  /* ── Progress bar ── */
  .progress-wrap { background: #0f172a; border-radius: 4px; height: 4px; overflow: hidden; }
  .progress-fill { height: 100%; border-radius: 4px; transition: width .4s; }
  .progress-green { background: var(--green); }
  .progress-blue { background: var(--blue); }
  .progress-amber { background: var(--amber); }

  /* ── Tab 1: Tasks ── */
  .tasks-layout {
    display: grid;
    grid-template-columns: 40% 60%;
    gap: 16px;
    height: calc(100vh - 84px);
  }
  .task-list-panel {
    overflow-y: auto;
    display: flex; flex-direction: column; gap: 10px;
    padding-right: 4px;
  }
  .task-detail-panel {
    overflow-y: auto;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 20px;
  }
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
  .task-card-header { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
  .task-title { font-weight: 600; font-size: 13px; flex: 1; }
  .task-meta { display: flex; align-items: center; gap: 6px; margin-bottom: 8px; }
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
  }
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

  /* ── Tab 2: Memory ── */
  .memory-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 14px;
    margin-bottom: 20px;
  }
  .mem-card { position: relative; }
  .mem-card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
  .mem-name { font-size: 14px; font-weight: 700; }
  .mem-metrics { display: flex; flex-direction: column; gap: 5px; }
  .mem-metric { display: flex; justify-content: space-between; font-size: 12px; }
  .mem-metric-key { color: var(--muted); }
  .mem-metric-val { color: var(--text); font-weight: 500; }

  /* System status row */
  .sys-row {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
  }
  .sys-card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 14px;
    display: flex; flex-direction: column; gap: 4px;
  }
  .sys-icon { font-size: 20px; margin-bottom: 4px; }
  .sys-label { font-size: 11px; color: var(--muted); }
  .sys-value { font-size: 18px; font-weight: 700; }
  .sys-sub { font-size: 11px; color: var(--muted); }
  .disk-track { background: #0f172a; border-radius: 3px; height: 3px; overflow: hidden; margin-top: 6px; }
  .disk-fill { height: 100%; border-radius: 3px; }
  .disk-ok { background: var(--green); }
  .disk-warn { background: var(--amber); }
  .disk-err { background: var(--rose); }

  /* ── Tab 3: Users ── */
  .users-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
  .users-title { font-size: 16px; font-weight: 700; }
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

  /* i18n */
  [data-lang="en"] .i18n-zh { display: none; }
  [data-lang="zh"] .i18n-en { display: none; }

  /* Section headers */
  .section-header { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .8px; margin-bottom: 10px; padding-bottom: 6px; border-bottom: 1px solid var(--border); }

  /* Mobile */
  @media (max-width: 768px) {
    .tasks-layout {
      grid-template-columns: 1fr;
      height: auto;
    }
    .task-list-panel { max-height: 50vh; }
    .memory-grid { grid-template-columns: repeat(2, 1fr); }
    .sys-row { grid-template-columns: repeat(2, 1fr); }
    .nav-time { display: none; }
  }
  @media (max-width: 480px) {
    .memory-grid { grid-template-columns: 1fr; }
    .sys-row { grid-template-columns: 1fr; }
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

<!-- Tab: Tasks -->
<div class="tab-content active" id="tab-tasks">
  <div class="page">
    <div class="tasks-layout">
      <div class="task-list-panel" id="taskList">
        <!-- Task cards injected here -->
      </div>
      <div class="task-detail-panel" id="taskDetail">
        <div class="detail-empty">
          <div>
            <div style="font-size:32px;margin-bottom:8px">📋</div>
            <span class="i18n-zh">點擊左側任務查看詳情</span>
            <span class="i18n-en">Click a task to view details</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- Tab: Memory -->
<div class="tab-content" id="tab-memory">
  <div class="page">
    <div class="section-header" style="margin-bottom:16px">
      <span class="i18n-zh">記憶層狀態</span>
      <span class="i18n-en">Memory Layer Status</span>
    </div>
    <div class="memory-grid" id="memoryGrid">
      <!-- Memory cards injected here -->
    </div>
    <div class="section-header" style="margin-bottom:12px">
      <span class="i18n-zh">系統狀態</span>
      <span class="i18n-en">System Status</span>
    </div>
    <div class="sys-row" id="sysRow">
      <!-- System status injected here -->
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
    <div class="card">
      <table class="users-table">
        <thead>
          <tr>
            <th><span class="i18n-zh">使用者名稱</span><span class="i18n-en">Username</span></th>
            <th><span class="i18n-zh">角色</span><span class="i18n-en">Role</span></th>
            <th><span class="i18n-zh">建立時間</span><span class="i18n-en">Created</span></th>
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
    <div class="modal-title">
      <span class="i18n-zh">新增使用者</span>
      <span class="i18n-en">Add User</span>
    </div>
    <div class="form-group">
      <label class="form-label"><span class="i18n-zh">使用者名稱</span><span class="i18n-en">Username</span></label>
      <input class="form-input" id="newUsername" type="text" autocomplete="off">
    </div>
    <div class="form-group">
      <label class="form-label"><span class="i18n-zh">密碼</span><span class="i18n-en">Password</span></label>
      <input class="form-input" id="newPassword" type="password" autocomplete="new-password">
    </div>
    <div class="form-group">
      <label class="form-label"><span class="i18n-zh">角色</span><span class="i18n-en">Role</span></label>
      <select class="form-select" id="newRole">
        <option value="admin">Admin</option>
        <option value="agent">Agent</option>
        <option value="viewer">Viewer</option>
      </select>
    </div>
    <div class="modal-actions">
      <button class="btn-ghost" onclick="closeModal()">
        <span class="i18n-zh">取消</span><span class="i18n-en">Cancel</span>
      </button>
      <button class="btn-primary" onclick="addUser()">
        <span class="i18n-zh">新增</span><span class="i18n-en">Add</span>
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
let isAdmin = true; // In production, derive from auth token

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
    // Fallback to embedded initial data
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
  document.getElementById('tab-tasks').querySelector('.page').prepend(el);
}

// ─── Render all ───
function renderAll() {
  if (!appData) return;
  const m = appData.memory || {};
  const ts = m.timestamp || new Date().toLocaleString('zh-TW');
  document.getElementById('lastUpdate').textContent = ts;

  renderTasks(appData.tasks || [], appData.progress || []);
  renderMemory(m);
  renderUsers(appData.users || []);

  if (isAdmin) {
    document.getElementById('usersTabBtn').style.display = '';
  }
}

// ─── Tasks ───
function renderTasks(tasks, progress) {
  const listEl = document.getElementById('taskList');
  listEl.innerHTML = '';

  if (!tasks.length) {
    listEl.innerHTML = '<div style="color:var(--muted);text-align:center;padding:40px 0">No tasks found</div>';
    return;
  }

  tasks.forEach((task, idx) => {
    const done = task.subtasks.filter(s => s.done).length;
    const total = task.subtasks.length;
    const pct = total > 0 ? Math.round(done / total * 100) : (task.status === 'done' ? 100 : 0);
    const statusClass = task.status || 'pending';
    const progressCls = statusClass === 'done' ? 'progress-green' : statusClass === 'in_progress' ? 'progress-blue' : 'progress-amber';
    const isSelected = task.id === selectedTaskId;

    const card = document.createElement('div');
    card.className = `task-card status-${statusClass} fade-in${isSelected ? ' selected' : ''}`;
    card.style.animationDelay = (idx * 0.04) + 's';
    card.innerHTML = `
      <div class="task-card-header">
        <span class="badge badge-${task.priority?.toLowerCase() || 'p3'}">${task.priority || 'P3'}</span>
        <span class="task-title">${task.title}</span>
      </div>
      <div class="task-meta">
        <span class="badge badge-cat">${task.category || 'General'}</span>
        ${statusBadge(task.status)}
      </div>
      ${total > 0 ? `
        <div class="task-progress-label">${done}/${total} subtasks</div>
        <div class="progress-wrap">
          <div class="progress-fill ${progressCls}" style="width:${pct}%"></div>
        </div>
      ` : ''}
    `;
    card.onclick = () => selectTask(task, progress);
    listEl.appendChild(card);
  });
}

function statusBadge(status) {
  const map = {
    done: ['badge-ok', '✓ Done', '✓ 完成'],
    in_progress: ['badge-warn', '⚡ In Progress', '⚡ 進行中'],
    pending: ['badge-p3', '⏳ Pending', '⏳ 待處理'],
  };
  const [cls, en, zh] = map[status] || map.pending;
  return `<span class="badge ${cls}"><span class="i18n-zh">${zh}</span><span class="i18n-en">${en}</span></span>`;
}

function selectTask(task, progress) {
  selectedTaskId = task.id;

  // Highlight selected card
  document.querySelectorAll('.task-card').forEach(c => c.classList.remove('selected'));
  event.currentTarget.classList.add('selected');

  // Render detail
  const done = task.subtasks.filter(s => s.done).length;
  const total = task.subtasks.length;

  // Find related progress entries (search title words in progress)
  const titleWords = task.title.toLowerCase().split(/[\s\/]+/).filter(w => w.length > 2);
  const related = progress.filter(e =>
    titleWords.some(w => e.title.toLowerCase().includes(w) || e.items.some(i => i.toLowerCase().includes(w)))
  ).slice(0, 5);

  const detailEl = document.getElementById('taskDetail');
  detailEl.innerHTML = `
    <div class="detail-title">${task.title}</div>
    <div class="detail-header">
      <span class="badge badge-${task.priority?.toLowerCase() || 'p3'}">${task.priority}</span>
      <span class="badge badge-cat">${task.category}</span>
      ${statusBadge(task.status)}
      ${total > 0 ? `<span style="font-size:12px;color:var(--muted)">${done}/${total} subtasks (${Math.round(done/total*100)}%)</span>` : ''}
    </div>

    ${task.subtasks.length > 0 ? `
      <div class="section-header">
        <span class="i18n-zh">子任務</span>
        <span class="i18n-en">Subtasks</span>
      </div>
      <div class="subtask-list">
        ${task.subtasks.map(s => `
          <div class="subtask-item${s.done ? ' done' : ''}">
            <div class="subtask-check${s.done ? ' checked' : ''}">${s.done ? '✓' : ''}</div>
            <div class="subtask-text${s.done ? ' done-text' : ''}">${s.text}</div>
          </div>
        `).join('')}
      </div>
    ` : '<div style="color:var(--muted);font-size:13px;margin-bottom:16px">No subtasks</div>'}

    ${related.length > 0 ? `
      <div class="timeline-section">
        <h4>
          <span class="i18n-zh">相關進度記錄</span>
          <span class="i18n-en">Related Progress</span>
        </h4>
        ${related.map(e => `
          <div class="timeline-entry fade-in">
            <div class="timeline-dot"></div>
            <div class="timeline-body">
              <div class="timeline-date">${e.date}</div>
              <div class="timeline-title-text">${e.title}</div>
              ${e.items.length > 0 ? `<div class="timeline-items">${e.items.slice(0,3).map(i => '• ' + i).join('<br>')}</div>` : ''}
            </div>
          </div>
        `).join('')}
      </div>
    ` : ''}
  `;
}

// ─── Memory ───
function renderMemory(m) {
  const grid = document.getElementById('memoryGrid');
  grid.innerHTML = '';

  const layers = [
    {
      key: 'l0', label: 'L0', name: { zh: 'Markdown 文件', en: 'Markdown Files' },
      metrics: m.l0 ? [
        { zh: '文件數', en: 'Files', val: m.l0.files },
        { zh: '大小', en: 'Size', val: m.l0.size_kb + ' KB' },
      ] : []
    },
    {
      key: 'l1', label: 'L1', name: { zh: 'lossless-claw', en: 'lossless-claw' },
      metrics: m.l1 ? [
        { zh: '摘要數', en: 'Summaries', val: m.l1.summaries },
        { zh: '模型', en: 'Model', val: shortModel(m.l1.model) },
        { zh: 'DB 大小', en: 'DB Size', val: m.l1.db_size_kb + ' KB' },
      ] : []
    },
    {
      key: 'l2', label: 'L2', name: { zh: 'LanceDB 向量', en: 'LanceDB Vector' },
      metrics: m.l2 ? [
        { zh: 'Lance 檔案', en: 'Lance Files', val: m.l2.lance_files },
        { zh: 'DB 大小', en: 'DB Size', val: m.l2.db_size_mb + ' MB' },
        { zh: '半衰期', en: 'Half-life', val: m.l2.halflife_days + ' days' },
      ] : []
    },
    {
      key: 'l3', label: 'L3', name: { zh: 'QMD BM25', en: 'QMD BM25' },
      metrics: m.l3 ? [
        { zh: '文件數', en: 'Documents', val: m.l3.documents },
        { zh: '引擎', en: 'Engine', val: m.l3.engine },
      ] : []
    },
    {
      key: 'l2plus', label: 'L2+', name: { zh: 'MemOS 知識圖譜', en: 'MemOS Knowledge Graph' },
      metrics: m.l2plus ? [
        { zh: '搜索延遲', en: 'Search Latency', val: m.l2plus.search_latency_ms >= 0 ? m.l2plus.search_latency_ms + ' ms' : 'N/A' },
        { zh: 'LLM', en: 'LLM', val: shortModel(m.l2plus.llm_model) },
        { zh: 'Neo4j', en: 'Neo4j', val: m.l2plus.neo4j },
        { zh: 'Qdrant', en: 'Qdrant', val: m.l2plus.qdrant },
      ] : []
    },
    {
      key: 'l4', label: 'L4', name: { zh: 'Cognee 深度理解', en: 'Cognee Deep Cognition' },
      metrics: m.l4 ? [
        { zh: '搜索延遲', en: 'Search Latency', val: m.l4.search_latency_ms >= 0 ? m.l4.search_latency_ms + ' ms' : 'N/A' },
        { zh: 'LLM', en: 'LLM', val: shortModel(m.l4.llm_model) },
      ] : []
    },
  ];

  layers.forEach((layer, idx) => {
    const data = m[layer.key] || {};
    const status = data.status || 'warn';
    const card = document.createElement('div');
    card.className = 'card mem-card fade-in';
    card.style.animationDelay = (idx * 0.06) + 's';
    card.innerHTML = `
      <div class="mem-card-header">
        <div style="display:flex;align-items:center;gap:8px">
          <span class="badge badge-layer">${layer.label}</span>
          <span class="mem-name">
            <span class="i18n-zh">${layer.name.zh}</span>
            <span class="i18n-en">${layer.name.en}</span>
          </span>
        </div>
        <span class="badge badge-${status === 'ok' ? 'ok' : status === 'warn' ? 'warn' : 'err'}">
          ${status === 'ok' ? '✓ OK' : status === 'warn' ? '⚠ Warn' : '✗ Err'}
        </span>
      </div>
      <div class="mem-metrics">
        ${layer.metrics.map(metric => `
          <div class="mem-metric">
            <span class="mem-metric-key">
              <span class="i18n-zh">${metric.zh}</span>
              <span class="i18n-en">${metric.en}</span>
            </span>
            <span class="mem-metric-val">${metric.val ?? '—'}</span>
          </div>
        `).join('')}
      </div>
    `;
    grid.appendChild(card);
  });

  // System status row
  const sysRow = document.getElementById('sysRow');
  sysRow.innerHTML = '';

  // Gateway
  const gw = m.gateway || {};
  sysRow.innerHTML += `
    <div class="sys-card fade-in">
      <div class="sys-icon">🌐</div>
      <div class="sys-label">Gateway</div>
      <div class="sys-value" style="color:var(--${gw.status === 'ok' ? 'green' : 'amber'})">${gw.status === 'ok' ? 'OK' : 'Warn'}</div>
      <div class="sys-sub">${gw.critical_issues ?? 0} critical issues</div>
    </div>`;

  // Disk /
  const diskRootPct = parseInt((m.disk?.root || '0%'));
  const diskRootCls = diskRootPct > 85 ? 'err' : diskRootPct > 70 ? 'warn' : 'ok';
  sysRow.innerHTML += `
    <div class="sys-card fade-in" style="animation-delay:.06s">
      <div class="sys-icon">💾</div>
      <div class="sys-label">Disk /</div>
      <div class="sys-value" style="color:var(--${diskRootCls === 'ok' ? 'green' : diskRootCls === 'warn' ? 'amber' : 'rose'})">${m.disk?.root || '—'}</div>
      <div class="disk-track"><div class="disk-fill disk-${diskRootCls}" style="width:${diskRootPct}%"></div></div>
    </div>`;

  // Disk /Users
  const diskUsersPct = parseInt((m.disk?.users || '0%'));
  const diskUsersCls = diskUsersPct > 85 ? 'err' : diskUsersPct > 70 ? 'warn' : 'ok';
  sysRow.innerHTML += `
    <div class="sys-card fade-in" style="animation-delay:.12s">
      <div class="sys-icon">🏠</div>
      <div class="sys-label">Disk /Users</div>
      <div class="sys-value" style="color:var(--${diskUsersCls === 'ok' ? 'green' : diskUsersCls === 'warn' ? 'amber' : 'rose'})">${m.disk?.users || '—'}</div>
      <div class="disk-track"><div class="disk-fill disk-${diskUsersCls}" style="width:${diskUsersPct}%"></div></div>
    </div>`;

  // NAS Docker
  const nasOk = m.l2plus?.status === 'ok' && m.l4?.status === 'ok';
  const nasCls = nasOk ? 'ok' : (m.l2plus?.status !== 'error' && m.l4?.status !== 'error') ? 'warn' : 'err';
  sysRow.innerHTML += `
    <div class="sys-card fade-in" style="animation-delay:.18s">
      <div class="sys-icon">🐳</div>
      <div class="sys-label">NAS Docker</div>
      <div class="sys-value" style="color:var(--${nasCls === 'ok' ? 'green' : nasCls === 'warn' ? 'amber' : 'rose'})">${nasOk ? 'Running' : 'Partial'}</div>
      <div class="sys-sub">MemOS + Cognee<br>10.10.10.66</div>
    </div>`;
}

function shortModel(m) {
  if (!m || m === 'unknown') return '—';
  return m.replace('MiniMax-M2.7-highspeed', 'M2.7-HS').replace('openai/', '').replace('anthropic/', '');
}

// ─── Users ───
function renderUsers(users) {
  const tbody = document.getElementById('usersTableBody');
  tbody.innerHTML = '';
  users.forEach(u => {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td><b>${u.username}</b></td>
      <td><span class="badge ${u.role === 'admin' ? 'badge-p1' : 'badge-p3'}">${u.role}</span></td>
      <td style="color:var(--muted)">${u.created || '—'}</td>
      <td>
        <button class="btn-sm" onclick="editUser('${u.username}')">
          <span class="i18n-zh">編輯</span><span class="i18n-en">Edit</span>
        </button>
        <button class="btn-sm btn-sm-danger" onclick="deleteUser('${u.username}')" style="margin-left:4px">
          <span class="i18n-zh">刪除</span><span class="i18n-en">Delete</span>
        </button>
      </td>
    `;
    tbody.appendChild(tr);
  });
}

function openAddUser() {
  document.getElementById('newUsername').value = '';
  document.getElementById('newPassword').value = '';
  document.getElementById('newRole').value = 'viewer';
  document.getElementById('userModal').classList.add('open');
  setTimeout(() => document.getElementById('newUsername').focus(), 100);
}

function closeModal() {
  document.getElementById('userModal').classList.remove('open');
}

function addUser() {
  const username = document.getElementById('newUsername').value.trim();
  const role = document.getElementById('newRole').value;
  if (!username) return;
  // In real app: POST to /api/users
  if (!appData.users) appData.users = [];
  appData.users.push({ username, role, created: new Date().toISOString().split('T')[0] });
  renderUsers(appData.users);
  closeModal();
}

function editUser(username) {
  alert('Edit user: ' + username + ' (UI placeholder — connect to /api/users PUT)');
}

function deleteUser(username) {
  if (!confirm('Delete user: ' + username + '?')) return;
  if (appData.users) {
    appData.users = appData.users.filter(u => u.username !== username);
    renderUsers(appData.users);
  }
}

// Close modal on overlay click
document.getElementById('userModal').addEventListener('click', function(e) {
  if (e.target === this) closeModal();
});

// ─── Init ───
window.addEventListener('DOMContentLoaded', () => {
  // Try API first; fallback to embedded data
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

# ── Embed initial data into HTML ──
echo "Embedding initial data..."
python3 << EMBEDEOF
import json
from pathlib import Path

outfile = Path('$OUTFILE')
tmpjson = Path('$TMPJSON')
task_data_raw = '''$TASK_DATA'''

html = outfile.read_text(encoding='utf-8')

try:
    mem_data = json.loads(tmpjson.read_text()) if tmpjson.exists() else {}
except:
    mem_data = {}

try:
    task_data = json.loads(task_data_raw)
except:
    task_data = {"tasks": [], "progress": [], "users": []}

merged = {**task_data, "memory": mem_data}
json_str = json.dumps(merged, ensure_ascii=False)

# Inject before </script> closing of the last script block
inject = f'\nwindow.__INITIAL_DATA__ = {json_str};\n'
html = html.replace('// ─── Init ───', inject + '// ─── Init ───')

outfile.write_text(html, encoding='utf-8')
print(f"Embedded {len(merged.get('tasks', []))} tasks, {len(merged.get('progress', []))} progress entries")
EMBEDEOF

# ── Sync to serve directory ──
SERVE_DIR="$HOME/.openclaw/dashboard-serve"
mkdir -p "$SERVE_DIR"
cp "$OUTFILE" "$SERVE_DIR/unified-dashboard.html"
echo "Copied to: $SERVE_DIR/unified-dashboard.html"

# ── Inject refresh button (using inject-refresh.sh if available) ──
INJECT_SCRIPT="$HOME/.openclaw/workspace/scripts/inject-refresh.sh"
if [ -f "$INJECT_SCRIPT" ]; then
    bash "$INJECT_SCRIPT" 2>/dev/null || true
fi

echo ""
echo "✅ Unified Dashboard generated successfully!"
echo "   Output: $OUTFILE"
echo "   Serve:  $SERVE_DIR/unified-dashboard.html"
echo "   Time:   $NOW"
