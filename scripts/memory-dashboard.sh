#!/bin/bash
# memory-dashboard.sh — Collect L0-L4 metrics and generate HTML dashboard
# Runs hourly via cron, outputs to ~/.openclaw/workspace/memory-dashboard.html

set -euo pipefail
OUTDIR="$HOME/.openclaw/workspace"
OUTFILE="$OUTDIR/memory-dashboard.html"
TMPJSON="/tmp/memory-dashboard-data.json"
NAS_IP="10.10.10.66"
DOCKER_BIN="/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker"
NOW=$(date '+%Y-%m-%d %H:%M:%S %Z')
EPOCH=$(date +%s)

# ─── Collect Metrics ───

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
    "api": f"http://10.10.10.66:8765",
    "search_latency_ms": memos_search_ms,
    "llm_model": memos_llm,
    "neo4j": "ok" if run("curl -sf --max-time 3 http://10.10.10.66:7474 -o /dev/null -w '%{http_code}'") == "200" else "error",
    "qdrant": "ok" if run("curl -sf --max-time 3 http://10.10.10.66:6333/collections -o /dev/null -w '%{http_code}'") == "200" else "error"
}

# L4: Cognee (NAS)
cognee_ok = False
cognee_search_ms = -1
try:
    # Login
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
    "api": f"http://10.10.10.66:8766",
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

DATA=$(collect)
echo "$DATA" > "$TMPJSON"

# ─── Generate HTML ───

python3 << HTMLEOF > "$OUTFILE"
import json, sys

with open("$TMPJSON") as f:
    m = json.load(f)

def badge(status):
    colors = {"ok": "#22c55e", "warn": "#eab308", "error": "#ef4444"}
    labels = {"ok": "✅ Healthy", "warn": "⚠️ Warning", "error": "❌ Error"}
    c = colors.get(status, "#94a3b8")
    l = labels.get(status, status)
    return f'<span style="background:{c};color:white;padding:2px 8px;border-radius:4px;font-size:0.85em">{l}</span>'

def ms_badge(ms):
    if ms < 0: return '<span style="color:#94a3b8">N/A</span>'
    c = "#22c55e" if ms < 500 else "#eab308" if ms < 2000 else "#ef4444"
    return f'<span style="color:{c};font-weight:bold">{ms}ms</span>'

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>🧠 Memory Dashboard — OpenClaw</title>
<meta http-equiv="refresh" content="3600">
<style>
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  body {{ font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif; background:#0f172a; color:#e2e8f0; padding:16px; }}
  .header {{ text-align:center; margin-bottom:24px; }}
  .header h1 {{ font-size:1.5em; margin-bottom:4px; }}
  .header .ts {{ color:#94a3b8; font-size:0.85em; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(300px,1fr)); gap:16px; }}
  .card {{ background:#1e293b; border-radius:12px; padding:16px; border:1px solid #334155; }}
  .card h2 {{ font-size:1.1em; margin-bottom:12px; display:flex; justify-content:space-between; align-items:center; }}
  .card .layer {{ color:#38bdf8; }}
  table {{ width:100%; border-collapse:collapse; }}
  td {{ padding:4px 0; font-size:0.9em; }}
  td:first-child {{ color:#94a3b8; width:40%; }}
  td:last-child {{ text-align:right; }}
  .footer {{ text-align:center; margin-top:24px; color:#64748b; font-size:0.8em; }}
  .status-row {{ display:flex; gap:8px; flex-wrap:wrap; justify-content:center; margin:12px 0; }}
  .mini-badge {{ padding:4px 10px; border-radius:6px; font-size:0.8em; }}
  .mini-ok {{ background:#166534; color:#86efac; }}
  .mini-err {{ background:#7f1d1d; color:#fca5a5; }}
</style>
</head>
<body>
<div class="header">
  <h1>🧠 Five-Layer Memory Dashboard</h1>
  <div class="ts">Last updated: {m['timestamp']}</div>
  <div class="status-row">
    <span class="mini-badge {'mini-ok' if m['l0']['status']=='ok' else 'mini-err'}">L0</span>
    <span class="mini-badge {'mini-ok' if m['l1']['status']=='ok' else 'mini-err'}">L1</span>
    <span class="mini-badge {'mini-ok' if m['l2']['status']=='ok' else 'mini-err'}">L2</span>
    <span class="mini-badge {'mini-ok' if m['l3']['status']=='ok' else 'mini-err'}">L3</span>
    <span class="mini-badge {'mini-ok' if m['l2plus']['status']=='ok' else 'mini-err'}">L2+</span>
    <span class="mini-badge {'mini-ok' if m['l4']['status']=='ok' else 'mini-err'}">L4</span>
    <span class="mini-badge {'mini-ok' if m['gateway']['status']=='ok' else 'mini-err'}">GW</span>
  </div>
</div>

<div class="grid">
  <!-- L0 -->
  <div class="card">
    <h2><span class="layer">L0</span> Markdown {badge(m['l0']['status'])}</h2>
    <table>
      <tr><td>Files</td><td>{m['l0']['files']}</td></tr>
      <tr><td>Size</td><td>{m['l0']['size_kb']} KB</td></tr>
      <tr><td>Content</td><td>{', '.join(m['l0']['names'][:5])}</td></tr>
    </table>
  </div>

  <!-- L1 -->
  <div class="card">
    <h2><span class="layer">L1</span> lossless-claw {badge(m['l1']['status'])}</h2>
    <table>
      <tr><td>Summaries</td><td>{m['l1']['summaries']}</td></tr>
      <tr><td>DB Size</td><td>{m['l1']['db_size_kb']} KB</td></tr>
      <tr><td>LLM</td><td>{m['l1']['model']}</td></tr>
    </table>
  </div>

  <!-- L2 -->
  <div class="card">
    <h2><span class="layer">L2</span> LanceDB Pro {badge(m['l2']['status'])}</h2>
    <table>
      <tr><td>Storage</td><td>{m['l2']['lance_files']} lance files ({m['l2']['db_size_mb']} MB)</td></tr>
      <tr><td>Embedding</td><td>{m['l2']['embedding_model']}</td></tr>
      <tr><td>Rerank</td><td>{m['l2']['rerank']}</td></tr>
      <tr><td>Decay</td><td>{m['l2']['halflife_days']}d half-life, {m['l2']['recency_weight']} weight</td></tr>
    </table>
  </div>

  <!-- L3 -->
  <div class="card">
    <h2><span class="layer">L3</span> QMD {badge(m['l3']['status'])}</h2>
    <table>
      <tr><td>Documents</td><td>{m['l3']['documents']}</td></tr>
      <tr><td>Engine</td><td>{m['l3']['engine']}</td></tr>
    </table>
  </div>

  <!-- L2+ -->
  <div class="card">
    <h2><span class="layer">L2+</span> MemOS (NAS) {badge(m['l2plus']['status'])}</h2>
    <table>
      <tr><td>API</td><td>{m['l2plus']['api']}</td></tr>
      <tr><td>Search Latency</td><td>{ms_badge(m['l2plus']['search_latency_ms'])}</td></tr>
      <tr><td>LLM</td><td>{m['l2plus']['llm_model']}</td></tr>
      <tr><td>Neo4j</td><td>{badge(m['l2plus']['neo4j'])}</td></tr>
      <tr><td>Qdrant</td><td>{badge(m['l2plus']['qdrant'])}</td></tr>
    </table>
  </div>

  <!-- L4 -->
  <div class="card">
    <h2><span class="layer">L4</span> Cognee (NAS) {badge(m['l4']['status'])}</h2>
    <table>
      <tr><td>API</td><td>{m['l4']['api']}</td></tr>
      <tr><td>Search Latency</td><td>{ms_badge(m['l4']['search_latency_ms'])}</td></tr>
      <tr><td>LLM</td><td>{m['l4']['llm_model']}</td></tr>
    </table>
  </div>

  <!-- System -->
  <div class="card">
    <h2><span class="layer">⚙️</span> System {badge(m['gateway']['status'])}</h2>
    <table>
      <tr><td>Gateway</td><td>{m['gateway']['critical_issues']} critical</td></tr>
      <tr><td>Disk /</td><td>{m['disk']['root']}</td></tr>
      <tr><td>Disk /Users</td><td>{m['disk']['users']}</td></tr>
    </table>
  </div>
</div>

<div class="footer">
  OpenClaw Five-Layer Memory Stack — Scott#4 (Mac Mini)<br>
  Auto-refreshes hourly via cron
</div>
</body>
</html>"""

print(html)
HTMLEOF

echo "Dashboard generated: $OUTFILE"
echo "Timestamp: $NOW"
