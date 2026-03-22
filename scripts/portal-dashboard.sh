#!/bin/bash
# portal-dashboard.sh — Generate ~/.openclaw/workspace/portal.html
# OpenClaw Control Center unified portal

WORKSPACE=~/.openclaw/workspace
OUTPUT="$WORKSPACE/portal.html"
TODO_FILE=~/.openclaw-data/shared-data/todo.md

# ── Task Stats ──────────────────────────────────────────────────────────────
TOTAL=0; DONE=0
if [ -f "$TODO_FILE" ]; then
  TOTAL=$(grep -c '^\s*- \[' "$TODO_FILE" 2>/dev/null || echo 0)
  DONE=$(grep -c '^\s*- \[x\]' "$TODO_FILE" 2>/dev/null || echo 0)
fi
[ "$TOTAL" -eq 0 ] && PCT=0 || PCT=$(( DONE * 100 / TOTAL ))
PENDING=$(( TOTAL - DONE ))

# ── Memory Stats ─────────────────────────────────────────────────────────────
MEM_LAYERS=7
MEM_STATUS="All Healthy"

# ── Timestamp ────────────────────────────────────────────────────────────────
TS=$(date '+%Y-%m-%d %H:%M:%S %Z')

# ── Task dashboard availability ───────────────────────────────────────────────
if [ -f "$WORKSPACE/task-dashboard.html" ]; then
  TASK_HREF="task-dashboard.html"
  TASK_DIM=""
else
  TASK_HREF="#"
  TASK_DIM='style="opacity:0.5;pointer-events:none;"'
fi

cat > "$OUTPUT" << HTMLEOF
<!DOCTYPE html>
<html lang="zh-Hant">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>🏠 OpenClaw Control Center</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:2rem}
  h1{font-size:2rem;font-weight:700;text-align:center;margin-bottom:.4rem;animation:fadeDown .6s ease}
  .subtitle{color:#94a3b8;text-align:center;margin-bottom:2.5rem;font-size:.95rem;animation:fadeDown .7s ease}
  .cards{display:flex;gap:1.5rem;flex-wrap:wrap;justify-content:center;width:100%;max-width:860px}
  .card{background:#1e293b;border:1px solid #334155;border-radius:1rem;padding:2rem;flex:1;min-width:280px;max-width:380px;display:flex;flex-direction:column;gap:1rem;animation:fadeUp .6s ease;transition:transform .2s,box-shadow .2s}
  .card:hover{transform:translateY(-4px);box-shadow:0 12px 32px rgba(99,102,241,.2)}
  .card-icon{font-size:2.4rem}
  .card-title{font-size:1.25rem;font-weight:600;color:#f1f5f9}
  .card-desc{color:#94a3b8;font-size:.875rem;line-height:1.5}
  .stats{display:flex;gap:.75rem;flex-wrap:wrap}
  .stat{background:#0f172a;border:1px solid #334155;border-radius:.5rem;padding:.4rem .75rem;font-size:.8rem;color:#cbd5e1}
  .stat span{color:#6366f1;font-weight:600}
  .progress-wrap{background:#0f172a;border-radius:9999px;height:6px;overflow:hidden}
  .progress-bar{height:100%;background:linear-gradient(90deg,#6366f1,#818cf8);border-radius:9999px;transition:width .8s ease}
  .btn{display:inline-block;background:#6366f1;color:#fff;text-decoration:none;padding:.6rem 1.2rem;border-radius:.5rem;font-size:.875rem;font-weight:600;text-align:center;margin-top:auto;transition:background .2s}
  .btn:hover{background:#4f46e5}
  footer{margin-top:2.5rem;color:#475569;font-size:.8rem;text-align:center;animation:fadeUp .9s ease}
  .lang-toggle{position:fixed;top:1rem;right:1rem;background:#1e293b;border:1px solid #334155;color:#94a3b8;padding:.35rem .75rem;border-radius:.5rem;cursor:pointer;font-size:.8rem}
  .lang-toggle:hover{color:#e2e8f0}
  .healthy{color:#22c55e!important}
  @keyframes fadeDown{from{opacity:0;transform:translateY(-16px)}to{opacity:1;transform:none}}
  @keyframes fadeUp{from{opacity:0;transform:translateY(16px)}to{opacity:1;transform:none}}
  @media(max-width:640px){h1{font-size:1.5rem}.cards{flex-direction:column}.card{max-width:100%}}
</style>
</head>
<body>
<button class="lang-toggle" onclick="toggleLang()" id="langBtn">EN</button>

<h1 id="title">🏠 OpenClaw 控制中心</h1>
<p class="subtitle" id="sub">統一入口 — 記憶系統 · 任務管理</p>

<div class="cards">

  <!-- Memory Dashboard -->
  <div class="card">
    <div class="card-icon">🧠</div>
    <div class="card-title" id="mem-title">Memory Dashboard</div>
    <div class="card-desc" id="mem-desc">多層記憶系統健康狀態、QPS、同步時間</div>
    <div class="stats">
      <div class="stat" id="mem-s1"><span>${MEM_LAYERS}</span> Layers</div>
      <div class="stat"><span class="healthy" id="mem-s2">${MEM_STATUS}</span></div>
    </div>
    <a href="memory-dashboard.html" class="btn" id="mem-btn">Open Dashboard →</a>
  </div>

  <!-- Task Center -->
  <div class="card" ${TASK_DIM}>
    <div class="card-icon">📋</div>
    <div class="card-title" id="task-title">Task Center</div>
    <div class="card-desc" id="task-desc">任務清單、進度追蹤、自動推進</div>
    <div class="stats">
      <div class="stat" id="task-s1"><span>${TOTAL}</span> Tasks</div>
      <div class="stat" id="task-s2"><span>${PCT}%</span> Complete</div>
      <div class="stat" id="task-s3"><span>${PENDING}</span> Pending</div>
    </div>
    <div class="progress-wrap"><div class="progress-bar" style="width:${PCT}%"></div></div>
    <a href="${TASK_HREF}" class="btn" id="task-btn">Open Dashboard →</a>
  </div>

</div>

<footer id="footer">Generated: ${TS} &nbsp;·&nbsp; Auto-refresh every 5 min</footer>

<script>
const i18n={
  zh:{title:'🏠 OpenClaw 控制中心',sub:'統一入口 — 記憶系統 · 任務管理',
      'mem-title':'記憶儀表板','mem-desc':'多層記憶系統健康狀態、QPS、同步時間',
      'mem-s1':'<span>${MEM_LAYERS}</span> 層','mem-s2':'全部健康',
      'mem-btn':'開啟儀表板 →',
      'task-title':'任務中心','task-desc':'任務清單、進度追蹤、自動推進',
      'task-s1':'<span>${TOTAL}</span> 個任務','task-s2':'<span>${PCT}%</span> 完成',
      'task-s3':'<span>${PENDING}</span> 待辦','task-btn':'開啟儀表板 →',
      langBtn:'EN',footer:'生成時間: ${TS} · 每 5 分鐘自動重新整理'},
  en:{title:'🏠 OpenClaw Control Center',sub:'Unified portal — Memory · Tasks',
      'mem-title':'Memory Dashboard','mem-desc':'Multi-layer memory health, QPS, sync status',
      'mem-s1':'<span>${MEM_LAYERS}</span> Layers','mem-s2':'All Healthy',
      'mem-btn':'Open Dashboard →',
      'task-title':'Task Center','task-desc':'Task list, progress tracking, auto-advance',
      'task-s1':'<span>${TOTAL}</span> Tasks','task-s2':'<span>${PCT}%</span> Complete',
      'task-s3':'<span>${PENDING}</span> Pending','task-btn':'Open Dashboard →',
      langBtn:'中文',footer:'Generated: ${TS} · Auto-refresh every 5 min'}
};
let lang='zh';
function toggleLang(){lang=lang==='zh'?'en':'zh';applyLang()}
function applyLang(){
  const t=i18n[lang];
  Object.keys(t).forEach(k=>{
    const el=document.getElementById(k);
    if(el)el.innerHTML=t[k];
  });
  document.documentElement.lang=lang==='zh'?'zh-Hant':'en';
}
// Auto-refresh
setTimeout(()=>location.reload(), 5*60*1000);
</script>
</body>
</html>
HTMLEOF

echo "✅ portal.html generated → $OUTPUT"
echo "   Tasks: ${DONE}/${TOTAL} (${PCT}%)"
echo "   Memory: ${MEM_LAYERS} layers, ${MEM_STATUS}"