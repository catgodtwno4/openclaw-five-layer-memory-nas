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

python3 << 'HTMLEOF' > "$OUTFILE"
import json, sys

with open("/tmp/memory-dashboard-data.json") as f:
    m = json.load(f)

data_json = json.dumps(m, ensure_ascii=False)

html = f"""<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="refresh" content="300">
<title>🧠 Memory Dashboard — OpenClaw</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
:root{{
  --bg:#0f172a;--bg-card:#1e293b;--bg-card-hover:#263245;
  --border:rgba(255,255,255,.08);--border-glow:rgba(99,102,241,.25);
  --text:#e2e8f0;--text-sec:#94a3b8;--text-muted:#475569;
  --pri:#818cf8;--pri-dark:#6366f1;
  --pri-grad:linear-gradient(135deg,#818cf8,#6366f1);
  --green:#34d399;--green-bg:rgba(52,211,153,.12);--green-dark:#059669;
  --amber:#fbbf24;--amber-bg:rgba(251,191,36,.12);
  --rose:#ef4444;--rose-bg:rgba(239,68,68,.12);
  --blue:#38bdf8;--violet:#a78bfa;
  --shadow:0 4px 24px rgba(0,0,0,.4);--shadow-lg:0 16px 48px rgba(0,0,0,.5);
  --radius:12px;--radius-lg:16px;
  --minimax:#3b82f6;--siliconflow:#10b981;--openai:#a855f7;--anthropic:#f59e0b;
}}
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Inter',Roboto,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;overflow-x:hidden}}

/* ── Animations ── */
@keyframes fadeInUp{{from{{opacity:0;transform:translateY(16px)}}to{{opacity:1;transform:translateY(0)}}}}
@keyframes pulse{{0%,100%{{opacity:1}}50%{{opacity:.5}}}}
@keyframes shimmer{{0%{{background-position:-200% 0}}100%{{background-position:200% 0}}}}
@keyframes dotPulse{{0%,100%{{transform:scale(1);box-shadow:0 0 0 0 currentColor}}50%{{transform:scale(1.15);box-shadow:0 0 0 4px transparent}}}}
.fade-in{{animation:fadeInUp .45s ease both}}
.delay-1{{animation-delay:.05s}}.delay-2{{animation-delay:.1s}}.delay-3{{animation-delay:.15s}}
.delay-4{{animation-delay:.2s}}.delay-5{{animation-delay:.25s}}.delay-6{{animation-delay:.3s}}
.delay-7{{animation-delay:.35s}}

/* ── Topbar ── */
.topbar{{
  background:rgba(15,23,42,.95);
  border-bottom:1px solid var(--border);
  backdrop-filter:blur(12px);
  position:sticky;top:0;z-index:100;
  padding:0 20px;
  display:flex;align-items:center;justify-content:space-between;
  height:56px;gap:12px;
}}
.topbar-brand{{display:flex;align-items:center;gap:10px;flex-shrink:0}}
.topbar-brand .logo-icon{{width:32px;height:32px;background:var(--pri-grad);border-radius:8px;display:flex;align-items:center;justify-content:center;font-size:17px}}
.topbar-brand h1{{font-size:15px;font-weight:700;letter-spacing:-.02em;color:var(--text)}}
.topbar-brand .sub{{font-size:11px;color:var(--text-sec);margin-top:-2px}}

/* Layer status dots */
.layer-nav{{display:flex;align-items:center;gap:6px;flex:1;justify-content:center;flex-wrap:wrap}}
.layer-dot{{display:flex;align-items:center;gap:5px;padding:4px 10px;border-radius:20px;background:rgba(255,255,255,.04);border:1px solid var(--border);cursor:default;transition:all .2s;font-size:12px;font-weight:600}}
.layer-dot:hover{{background:rgba(255,255,255,.08);border-color:var(--border-glow)}}
.layer-dot .dot{{width:7px;height:7px;border-radius:50%;flex-shrink:0}}
.dot-ok{{background:var(--green);box-shadow:0 0 6px var(--green);animation:dotPulse 2.5s ease-in-out infinite}}
.dot-warn{{background:var(--amber);box-shadow:0 0 6px var(--amber)}}
.dot-err{{background:var(--rose);box-shadow:0 0 6px var(--rose);animation:dotPulse 1.5s ease-in-out infinite}}

.topbar-actions{{display:flex;align-items:center;gap:8px;flex-shrink:0}}
.btn-i18n{{padding:5px 12px;border-radius:8px;border:1px solid var(--border);background:rgba(255,255,255,.04);color:var(--text-sec);font-size:12px;font-weight:600;cursor:pointer;transition:all .2s}}
.btn-i18n:hover{{border-color:var(--pri);color:var(--pri);background:rgba(99,102,241,.08)}}
.ts-badge{{font-size:11px;color:var(--text-muted);white-space:nowrap}}

/* ── Main layout ── */
.main{{padding:20px;max-width:1400px;margin:0 auto}}
.section-title{{font-size:12px;font-weight:700;color:var(--text-muted);letter-spacing:.08em;text-transform:uppercase;margin-bottom:12px;margin-top:24px;display:flex;align-items:center;gap:8px}}
.section-title::after{{content:'';flex:1;height:1px;background:var(--border)}}

/* ── Cards ── */
.cards-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:14px}}
.card{{
  background:var(--bg-card);
  border:1px solid var(--border);
  border-radius:var(--radius-lg);
  padding:18px;
  transition:all .25s;
  position:relative;
  overflow:hidden;
}}
.card::before{{
  content:'';position:absolute;top:0;left:0;right:0;height:2px;
  background:var(--card-accent,var(--pri-grad));
  opacity:.7;
}}
.card:hover{{border-color:var(--border-glow);box-shadow:var(--shadow);transform:translateY(-2px)}}
.card-header{{display:flex;align-items:flex-start;justify-content:space-between;margin-bottom:14px;gap:8px}}
.card-title{{display:flex;align-items:center;gap:8px}}
.card-layer-tag{{font-size:11px;font-weight:700;letter-spacing:.05em;padding:2px 8px;border-radius:6px;background:rgba(99,102,241,.15);color:var(--pri)}}
.card-name{{font-size:14px;font-weight:600;color:var(--text)}}
.card-desc{{font-size:11px;color:var(--text-muted);margin-top:1px}}

/* Status badge */
.status-badge{{display:inline-flex;align-items:center;gap:5px;padding:3px 9px;border-radius:20px;font-size:11px;font-weight:700;white-space:nowrap}}
.badge-ok{{background:var(--green-bg);color:var(--green);border:1px solid rgba(52,211,153,.2)}}
.badge-warn{{background:var(--amber-bg);color:var(--amber);border:1px solid rgba(251,191,36,.2)}}
.badge-err{{background:var(--rose-bg);color:var(--rose);border:1px solid rgba(239,68,68,.2)}}

/* Metrics table */
.metrics-table{{width:100%;border-collapse:collapse;margin-top:4px}}
.metrics-table tr{{border-bottom:1px solid rgba(255,255,255,.04)}}
.metrics-table tr:last-child{{border-bottom:none}}
.metrics-table td{{padding:6px 0;font-size:12.5px;vertical-align:middle}}
.metrics-table td.label{{color:var(--text-sec);width:45%;padding-right:8px}}
.metrics-table td.value{{color:var(--text);text-align:right;font-weight:500}}

/* Latency gauge */
.latency-gauge{{display:flex;align-items:center;gap:6px;justify-content:flex-end}}
.gauge-bar{{height:4px;border-radius:2px;background:rgba(255,255,255,.08);flex:1;max-width:60px;overflow:hidden}}
.gauge-fill{{height:100%;border-radius:2px;transition:width .6s ease}}
.gauge-ok{{background:var(--green)}}
.gauge-warn{{background:var(--amber)}}
.gauge-err{{background:var(--rose)}}
.latency-val{{font-size:12px;font-weight:700;min-width:48px;text-align:right}}
.latency-ok{{color:var(--green)}}
.latency-warn{{color:var(--amber)}}
.latency-err{{color:var(--rose)}}
.latency-na{{color:var(--text-muted)}}

/* Model badges */
.model-badge{{display:inline-flex;align-items:center;gap:4px;padding:2px 8px;border-radius:6px;font-size:11px;font-weight:600}}
.model-minimax{{background:rgba(59,130,246,.15);color:#60a5fa;border:1px solid rgba(59,130,246,.2)}}
.model-siliconflow{{background:rgba(16,185,129,.15);color:#34d399;border:1px solid rgba(16,185,129,.2)}}
.model-openai{{background:rgba(168,85,247,.15);color:#c084fc;border:1px solid rgba(168,85,247,.2)}}
.model-anthropic{{background:rgba(245,158,11,.15);color:#fbbf24;border:1px solid rgba(245,158,11,.2)}}
.model-default{{background:rgba(148,163,184,.1);color:var(--text-sec);border:1px solid var(--border)}}

/* Sub-status row */
.sub-status-row{{display:flex;gap:6px;margin-top:10px;flex-wrap:wrap}}
.sub-status{{display:flex;align-items:center;gap:4px;padding:3px 8px;border-radius:6px;font-size:11px;font-weight:600;background:rgba(255,255,255,.04);border:1px solid var(--border)}}
.sub-ok{{color:var(--green)}}
.sub-err{{color:var(--rose)}}

/* Injection limit */
.inject-bar{{margin-top:12px;padding-top:10px;border-top:1px solid var(--border)}}
.inject-label{{display:flex;justify-content:space-between;font-size:11px;color:var(--text-muted);margin-bottom:4px}}
.inject-track{{height:3px;background:rgba(255,255,255,.06);border-radius:2px;overflow:hidden}}
.inject-fill{{height:100%;border-radius:2px;background:var(--pri-grad);opacity:.6}}

/* ── Analytics section ── */
.analytics-wrap{{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius-lg);padding:20px;margin-top:14px}}
.analytics-wrap::before{{display:none}}
.chart-title{{font-size:13px;font-weight:600;color:var(--text-sec);margin-bottom:16px}}
.chart-container{{display:flex;align-items:flex-end;gap:10px;height:100px;position:relative}}
.chart-bar-wrap{{flex:1;display:flex;flex-direction:column;align-items:center;gap:6px}}
.chart-bar{{width:100%;border-radius:4px 4px 0 0;position:relative;cursor:default;transition:opacity .2s;min-height:3px}}
.chart-bar:hover{{opacity:.85}}
.chart-bar-ok{{background:linear-gradient(180deg,#34d399,#059669)}}
.chart-bar-warn{{background:linear-gradient(180deg,#fbbf24,#d97706)}}
.chart-bar-err{{background:linear-gradient(180deg,#ef4444,#dc2626)}}
.chart-label{{font-size:11px;color:var(--text-muted);text-align:center}}
.chart-val{{font-size:11px;font-weight:700;text-align:center}}
.chart-val-ok{{color:var(--green)}}
.chart-val-warn{{color:var(--amber)}}
.chart-val-err{{color:var(--rose)}}
.chart-val-na{{color:var(--text-muted)}}
.chart-baseline{{position:absolute;left:0;right:0;bottom:0;height:1px;background:var(--border)}}

/* ── System section ── */
.system-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-top:14px}}
.sys-card{{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius);padding:14px;transition:all .2s}}
.sys-card:hover{{border-color:var(--border-glow)}}
.sys-icon{{font-size:20px;margin-bottom:8px}}
.sys-label{{font-size:11px;color:var(--text-muted);font-weight:600;text-transform:uppercase;letter-spacing:.06em;margin-bottom:4px}}
.sys-value{{font-size:18px;font-weight:700;color:var(--text)}}
.sys-sub{{font-size:11px;color:var(--text-muted);margin-top:2px}}

/* disk usage */
.disk-pct-num{{font-size:22px;font-weight:800}}
.disk-track{{height:5px;background:rgba(255,255,255,.07);border-radius:3px;margin-top:8px;overflow:hidden}}
.disk-fill{{height:100%;border-radius:3px;transition:width .8s ease}}
.disk-ok{{background:var(--green)}}
.disk-warn{{background:var(--amber)}}
.disk-err{{background:var(--rose)}}

/* ── Footer ── */
.footer{{text-align:center;padding:28px 20px 20px;color:var(--text-muted);font-size:11.5px;line-height:1.8}}
.footer a{{color:var(--text-sec);text-decoration:none}}
.footer strong{{color:var(--text-sec)}}
.version-tag{{display:inline-flex;align-items:center;gap:4px;padding:2px 8px;background:rgba(99,102,241,.1);border:1px solid rgba(99,102,241,.2);border-radius:10px;font-size:10px;color:var(--pri);font-weight:700;margin-left:6px}}

/* ── Responsive ── */
@media(max-width:640px){{
  .topbar{{padding:0 12px;height:52px}}
  .topbar-brand h1{{font-size:13px}}
  .layer-nav{{gap:4px}}
  .layer-dot{{padding:3px 7px;font-size:11px}}
  .main{{padding:12px}}
  .cards-grid{{grid-template-columns:1fr}}
  .system-grid{{grid-template-columns:1fr 1fr}}
  .ts-badge{{display:none}}
}}
@media(max-width:380px){{
  .system-grid{{grid-template-columns:1fr}}
  .layer-nav{{gap:3px}}
  .layer-dot .dot-label{{display:none}}
}}

/* i18n hidden */
[data-lang="zh"] .i18n-en{{display:none!important}}
[data-lang="en"] .i18n-zh{{display:none!important}}
</style>
</head>
<body data-lang="zh">

<!-- ── Data ── -->
<script>
const DATA = {data_json};
</script>

<!-- ── Topbar ── -->
<header class="topbar">
  <div class="topbar-brand">
    <div class="logo-icon">🧠</div>
    <div>
      <h1><span class="i18n-zh">記憶儀表板</span><span class="i18n-en">Memory Dashboard</span></h1>
      <div class="sub">OpenClaw · Scott#4</div>
    </div>
  </div>

  <nav class="layer-nav" id="layerNav"></nav>

  <div class="topbar-actions">
    <span class="ts-badge" id="tsDisplay"></span>
    <button class="btn-i18n" onclick="toggleLang()" id="langBtn">EN</button>
  </div>
</header>

<!-- ── Main ── -->
<main class="main">

  <!-- Local Layers -->
  <div class="section-title"><span class="i18n-zh">本機記憶層</span><span class="i18n-en">Local Memory Layers</span></div>
  <div class="cards-grid" id="localCards"></div>

  <!-- NAS Layers -->
  <div class="section-title"><span class="i18n-zh">NAS 進階記憶層</span><span class="i18n-en">NAS Advanced Layers</span></div>
  <div class="cards-grid" id="nasCards"></div>

  <!-- Analytics -->
  <div class="section-title"><span class="i18n-zh">搜尋延遲分析</span><span class="i18n-en">Search Latency Analytics</span></div>
  <div class="analytics-wrap fade-in delay-6">
    <div class="chart-title"><span class="i18n-zh">L2+ / L4 API 回應時間（ms）</span><span class="i18n-en">L2+ / L4 API Response Time (ms)</span></div>
    <div class="chart-container" id="latencyChart"></div>
  </div>

  <!-- System -->
  <div class="section-title"><span class="i18n-zh">系統狀態</span><span class="i18n-en">System Status</span></div>
  <div class="system-grid" id="systemGrid"></div>

</main>

<!-- ── Footer ── -->
<footer class="footer">
  <div>
    <strong>OpenClaw Five-Layer Memory Stack</strong>
    <span class="version-tag">v2.0</span>
  </div>
  <div style="margin-top:4px">
    <span class="i18n-zh">最後更新：</span>
    <span class="i18n-en">Last updated: </span>
    <span id="footerTs"></span>
    &nbsp;·&nbsp;
    <span class="i18n-zh">每 5 分鐘自動刷新</span>
    <span class="i18n-en">Auto-refresh every 5 min</span>
  </div>
</footer>

<script>
// ── i18n ──
function toggleLang() {{
  const b = document.body;
  const btn = document.getElementById('langBtn');
  if (b.dataset.lang === 'zh') {{
    b.dataset.lang = 'en';
    btn.textContent = '中文';
  }} else {{
    b.dataset.lang = 'zh';
    btn.textContent = 'EN';
  }}
}}

// ── Helpers ──
function statusClass(s) {{
  return s === 'ok' ? 'ok' : s === 'warn' ? 'warn' : 'err';
}}
function statusBadge(s) {{
  const cls = statusClass(s);
  const labels = {{ok: '✅ Healthy', warn: '⚠️ Warning', err: '❌ Error'}};
  const label = labels[cls] || s;
  return `<span class="status-badge badge-${{cls}}">${{label}}</span>`;
}}
function statusBadgeI18n(s) {{
  const cls = statusClass(s);
  const zh = {{ok:'✅ 正常', warn:'⚠️ 警告', err:'❌ 異常'}};
  const en = {{ok:'✅ Healthy', warn:'⚠️ Warning', err:'❌ Error'}};
  return `<span class="status-badge badge-${{cls}}">
    <span class="i18n-zh">${{zh[cls]||s}}</span>
    <span class="i18n-en">${{en[cls]||s}}</span>
  </span>`;
}}
function latencyWidget(ms) {{
  if (ms < 0) return `<span class="latency-na">N/A</span>`;
  const cls = ms < 500 ? 'ok' : ms < 2000 ? 'warn' : 'err';
  const icon = cls === 'ok' ? '✓' : cls === 'warn' ? '⚠' : '✗';
  const pct = Math.min(100, (ms / 3000) * 100);
  return `<div class="latency-gauge">
    <div class="gauge-bar"><div class="gauge-fill gauge-${{cls}}" style="width:${{pct}}%"></div></div>
    <span class="latency-val latency-${{cls}}">${{ms}}ms</span>
  </div>`;
}}
function modelBadge(model) {{
  if (!model || model === 'unknown') return `<span class="model-badge model-default">—</span>`;
  const low = model.toLowerCase();
  let cls = 'model-default', label = model;
  if (low.includes('minimax') || low.includes('m2')) {{ cls = 'model-minimax'; label = '🔵 ' + model; }}
  else if (low.includes('silicon') || low.includes('qwen') || low.includes('glm')) {{ cls = 'model-siliconflow'; label = '🟢 ' + model; }}
  else if (low.includes('gpt') || low.includes('openai')) {{ cls = 'model-openai'; label = '🟣 ' + model; }}
  else if (low.includes('claude') || low.includes('anthropic')) {{ cls = 'model-anthropic'; label = '🟡 ' + model; }}
  return `<span class="model-badge ${{cls}}" title="${{model}}">${{label.length>38 ? label.slice(0,36)+'…' : label}}</span>`;
}}
function subStatus(label, status) {{
  const cls = statusClass(status);
  const icon = cls === 'ok' ? '●' : '●';
  return `<span class="sub-status sub-${{cls}}">${{icon}} ${{label}}</span>`;
}}
function injectBar(used, limit, labelZh, labelEn) {{
  const pct = used > 0 ? Math.max(2, Math.min(100, Math.round((used/limit)*100))) : 0;
  return `<div class="inject-bar">
    <div class="inject-label">
      <span class="i18n-zh"><span class="i18n-zh">${{labelZh}}</span></span>
      <span class="i18n-en"><span class="i18n-en">${{labelEn}}</span></span>
      <span style="color:var(--text-sec);font-weight:600">${{used}} / ${{limit}} tokens</span>
    </div>
    <div class="inject-track"><div class="inject-fill" style="width:${{pct}}%"></div></div>
  </div>`;
}}
function diskPct(s) {{
  if (!s) return 0;
  return parseInt(s.replace('%','')) || 0;
}}

// ── Layer Nav ──
const m = DATA;
const layers = [
  {{id:'L0', status:m.l0.status}},
  {{id:'L1', status:m.l1.status}},
  {{id:'L2', status:m.l2.status}},
  {{id:'L3', status:m.l3.status}},
  {{id:'L2+', status:m.l2plus.status}},
  {{id:'L4', status:m.l4.status}},
  {{id:'GW', status:m.gateway.status}},
];
const navEl = document.getElementById('layerNav');
layers.forEach(l => {{
  const cls = statusClass(l.status);
  navEl.innerHTML += `<div class="layer-dot">
    <span class="dot dot-${{cls}}"></span>
    <span class="dot-label">${{l.id}}</span>
  </div>`;
}});

// ── Timestamp ──
document.getElementById('tsDisplay').textContent = m.timestamp;
document.getElementById('footerTs').textContent = m.timestamp;

// ── Local Cards ──
const localCards = document.getElementById('localCards');

// L0
localCards.innerHTML += `<div class="card fade-in delay-1" style="--card-accent:linear-gradient(135deg,#38bdf8,#0284c7)">
  <div class="card-header">
    <div class="card-title">
      <span class="card-layer-tag">L0</span>
      <div>
        <div class="card-name"><span class="i18n-zh">Markdown 工作區</span><span class="i18n-en">Markdown Workspace</span></div>
        <div class="card-desc"><span class="i18n-zh">靜態上下文注入</span><span class="i18n-en">Static context injection</span></div>
      </div>
    </div>
    ${{statusBadgeI18n(m.l0.status)}}
  </div>
  <table class="metrics-table">
    <tr><td class="label"><span class="i18n-zh">檔案數</span><span class="i18n-en">Files</span></td><td class="value">${{m.l0.files}}</td></tr>
    <tr><td class="label"><span class="i18n-zh">總大小</span><span class="i18n-en">Size</span></td><td class="value">${{m.l0.size_kb}} KB</td></tr>
    <tr><td class="label"><span class="i18n-zh">包含</span><span class="i18n-en">Content</span></td><td class="value" style="font-size:11px;color:var(--text-sec)">${{m.l0.names.slice(0,4).join(', ')}}${{m.l0.names.length>4?' …':''}}</td></tr>
  </table>
  ${{injectBar(Math.round(m.l0.size_kb*0.25), 50000, '注入預估', 'Inject Est.')}}
</div>`;

// L1
localCards.innerHTML += `<div class="card fade-in delay-2" style="--card-accent:linear-gradient(135deg,#a78bfa,#7c3aed)">
  <div class="card-header">
    <div class="card-title">
      <span class="card-layer-tag">L1</span>
      <div>
        <div class="card-name">lossless-claw</div>
        <div class="card-desc"><span class="i18n-zh">對話摘要壓縮</span><span class="i18n-en">Conversation summary compression</span></div>
      </div>
    </div>
    ${{statusBadgeI18n(m.l1.status)}}
  </div>
  <table class="metrics-table">
    <tr><td class="label"><span class="i18n-zh">摘要數</span><span class="i18n-en">Summaries</span></td><td class="value">${{m.l1.summaries}}</td></tr>
    <tr><td class="label"><span class="i18n-zh">DB 大小</span><span class="i18n-en">DB Size</span></td><td class="value">${{m.l1.db_size_kb}} KB</td></tr>
    <tr><td class="label"><span class="i18n-zh">摘要模型</span><span class="i18n-en">LLM Model</span></td><td class="value">${{modelBadge(m.l1.model)}}</td></tr>
  </table>
  ${{injectBar(Math.round(m.l1.summaries * 120), 100000, '摘要用量', 'Summary usage')}}
</div>`;

// L2
localCards.innerHTML += `<div class="card fade-in delay-3" style="--card-accent:linear-gradient(135deg,#818cf8,#4f46e5)">
  <div class="card-header">
    <div class="card-title">
      <span class="card-layer-tag">L2</span>
      <div>
        <div class="card-name">LanceDB Pro</div>
        <div class="card-desc"><span class="i18n-zh">向量語義搜尋</span><span class="i18n-en">Vector semantic search</span></div>
      </div>
    </div>
    ${{statusBadgeI18n(m.l2.status)}}
  </div>
  <table class="metrics-table">
    <tr><td class="label"><span class="i18n-zh">存儲</span><span class="i18n-en">Storage</span></td><td class="value">${{m.l2.lance_files}} files · ${{m.l2.db_size_mb}} MB</td></tr>
    <tr><td class="label"><span class="i18n-zh">嵌入模型</span><span class="i18n-en">Embedding</span></td><td class="value" style="font-size:11px">${{m.l2.embedding_model}}</td></tr>
    <tr><td class="label">Rerank</td><td class="value" style="font-size:12px">${{m.l2.rerank}}</td></tr>
    <tr><td class="label"><span class="i18n-zh">衰減半衰期</span><span class="i18n-en">Decay half-life</span></td><td class="value">${{m.l2.halflife_days}}<span class="i18n-zh">天</span><span class="i18n-en">d</span> · weight ${{m.l2.recency_weight}}</td></tr>
  </table>
  ${{injectBar(Math.round(m.l2.db_size_mb * 2), 8000, '向量容量', 'Vector capacity')}}
</div>`;

// L3
localCards.innerHTML += `<div class="card fade-in delay-4" style="--card-accent:linear-gradient(135deg,#34d399,#059669)">
  <div class="card-header">
    <div class="card-title">
      <span class="card-layer-tag">L3</span>
      <div>
        <div class="card-name">QMD</div>
        <div class="card-desc"><span class="i18n-zh">BM25 全文索引</span><span class="i18n-en">BM25 full-text index</span></div>
      </div>
    </div>
    ${{statusBadgeI18n(m.l3.status)}}
  </div>
  <table class="metrics-table">
    <tr><td class="label"><span class="i18n-zh">文件數</span><span class="i18n-en">Documents</span></td><td class="value" style="font-size:16px;font-weight:700;color:var(--green)">${{m.l3.documents}}</td></tr>
    <tr><td class="label"><span class="i18n-zh">引擎</span><span class="i18n-en">Engine</span></td><td class="value">${{m.l3.engine}}</td></tr>
  </table>
  ${{injectBar(Math.round(m.l3.documents * 15), 5000, '索引容量', 'Index capacity')}}
</div>`;

// ── NAS Cards ──
const nasCards = document.getElementById('nasCards');

// L2+
nasCards.innerHTML += `<div class="card fade-in delay-5" style="--card-accent:linear-gradient(135deg,#fbbf24,#d97706)">
  <div class="card-header">
    <div class="card-title">
      <span class="card-layer-tag">L2+</span>
      <div>
        <div class="card-name">MemOS NAS</div>
        <div class="card-desc"><span class="i18n-zh">圖譜 + 向量混合記憶</span><span class="i18n-en">Graph + vector hybrid memory</span></div>
      </div>
    </div>
    ${{statusBadgeI18n(m.l2plus.status)}}
  </div>
  <table class="metrics-table">
    <tr><td class="label">API</td><td class="value" style="font-size:11px;color:var(--text-sec)">${{m.l2plus.api}}</td></tr>
    <tr><td class="label"><span class="i18n-zh">搜尋延遲</span><span class="i18n-en">Search Latency</span></td><td class="value">${{latencyWidget(m.l2plus.search_latency_ms)}}</td></tr>
    <tr><td class="label">LLM</td><td class="value">${{modelBadge(m.l2plus.llm_model)}}</td></tr>
  </table>
  <div class="sub-status-row">
    ${{subStatus('Neo4j', m.l2plus.neo4j)}}
    ${{subStatus('Qdrant', m.l2plus.qdrant)}}
  </div>
  ${{injectBar(800, 10000, '圖譜注入', 'Graph injection')}}
</div>`;

// L4
nasCards.innerHTML += `<div class="card fade-in delay-6" style="--card-accent:linear-gradient(135deg,#f472b6,#db2777)">
  <div class="card-header">
    <div class="card-title">
      <span class="card-layer-tag">L4</span>
      <div>
        <div class="card-name">Cognee NAS</div>
        <div class="card-desc"><span class="i18n-zh">知識圖譜推理</span><span class="i18n-en">Knowledge graph reasoning</span></div>
      </div>
    </div>
    ${{statusBadgeI18n(m.l4.status)}}
  </div>
  <table class="metrics-table">
    <tr><td class="label">API</td><td class="value" style="font-size:11px;color:var(--text-sec)">${{m.l4.api}}</td></tr>
    <tr><td class="label"><span class="i18n-zh">搜尋延遲</span><span class="i18n-en">Search Latency</span></td><td class="value">${{latencyWidget(m.l4.search_latency_ms)}}</td></tr>
    <tr><td class="label">LLM</td><td class="value">${{modelBadge(m.l4.llm_model)}}</td></tr>
  </table>
  ${{injectBar(600, 8000, '知識注入', 'Knowledge injection')}}
</div>`;

// ── Analytics Chart ──
function renderChart() {{
  const chart = document.getElementById('latencyChart');
  const entries = [
    {{label:'L2+ MemOS', ms:m.l2plus.search_latency_ms, zhLabel:'MemOS'}},
    {{label:'L4 Cognee', ms:m.l4.search_latency_ms, zhLabel:'Cognee'}},
  ];
  const maxMs = Math.max(3000, ...entries.filter(e=>e.ms>0).map(e=>e.ms));
  chart.innerHTML = '<div class="chart-baseline"></div>';
  entries.forEach(e => {{
    const cls = e.ms < 0 ? 'na' : e.ms < 500 ? 'ok' : e.ms < 2000 ? 'warn' : 'err';
    const pct = e.ms > 0 ? Math.max(4, Math.round((e.ms/maxMs)*96)) : 4;
    const valHtml = e.ms < 0
      ? `<span class="chart-val chart-val-na">N/A</span>`
      : `<span class="chart-val chart-val-${{cls}}">${{e.ms}}ms</span>`;
    chart.innerHTML += `<div class="chart-bar-wrap">
      <div class="chart-bar chart-bar-${{cls === 'na' ? 'err' : cls}}" style="height:${{e.ms>0?pct:0}}%" title="${{e.label}}: ${{e.ms}}ms"></div>
      ${{valHtml}}
      <div class="chart-label"><span class="i18n-zh">${{e.zhLabel}}</span><span class="i18n-en">${{e.label}}</span></div>
    </div>`;
  }});
}}
renderChart();

// ── System Grid ──
const sg = document.getElementById('systemGrid');
const gwCls = statusClass(m.gateway.status);
sg.innerHTML += `<div class="sys-card fade-in delay-7">
  <div class="sys-icon">🌐</div>
  <div class="sys-label">Gateway</div>
  <div class="sys-value" style="color:var(--${{gwCls === 'ok' ? 'green' : gwCls === 'warn' ? 'amber' : 'rose'}})">${{gwCls === 'ok' ? 'Online' : 'Issues'}}</div>
  <div class="sys-sub">${{m.gateway.critical_issues}} <span class="i18n-zh">嚴重問題</span><span class="i18n-en">critical issues</span></div>
</div>`;

function diskCard(pctStr, label, icon) {{
  const pct = diskPct(pctStr);
  const cls = pct < 70 ? 'ok' : pct < 90 ? 'warn' : 'err';
  return `<div class="sys-card fade-in delay-7">
    <div class="sys-icon">${{icon}}</div>
    <div class="sys-label">${{label}}</div>
    <div class="sys-value disk-pct-num" style="color:var(--${{cls==='ok'?'green':cls==='warn'?'amber':'rose'}})">${{pctStr||'—'}}</div>
    <div class="sys-sub"><span class="i18n-zh">磁碟使用率</span><span class="i18n-en">Disk usage</span></div>
    <div class="disk-track"><div class="disk-fill disk-${{cls}}" style="width:${{pct}}%"></div></div>
  </div>`;
}}
sg.innerHTML += diskCard(m.disk.root, 'Disk /', '💾');
sg.innerHTML += diskCard(m.disk.users, 'Disk /Users', '🏠');

// NAS container status
const nasOk = m.l2plus.status === 'ok' && m.l4.status === 'ok';
const nasCls = nasOk ? 'ok' : (m.l2plus.status !== 'error' && m.l4.status !== 'error') ? 'warn' : 'err';
sg.innerHTML += `<div class="sys-card fade-in delay-7">
  <div class="sys-icon">🐳</div>
  <div class="sys-label">NAS Docker</div>
  <div class="sys-value" style="color:var(--${{nasCls==='ok'?'green':nasCls==='warn'?'amber':'rose'}})">${{nasOk?'Running':'Partial'}}</div>
  <div class="sys-sub">MemOS + Cognee<br>10.10.10.66</div>
</div>`;
</script>
</body>
</html>"""

print(html)
HTMLEOF

echo "Dashboard generated: $OUTFILE"
echo "Timestamp: $NOW"
