#!/usr/bin/env bash
# task-dashboard.sh — Task Management Center Dashboard Generator
# Reads todo.md + progress-log.md → generates task-dashboard.html
# Usage: bash task-dashboard.sh [--output /path/to/output.html]

set -euo pipefail

TODO_FILE="${HOME}/.openclaw-data/shared-data/todo.md"
PROGRESS_FILE="${HOME}/.openclaw-data/shared-data/progress-log.md"
OUTPUT_FILE="${HOME}/.openclaw/workspace/task-dashboard.html"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Parse override
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ─── Parse todo.md with Python ───────────────────────────────────────────────
TASKS_JSON=$(python3 - "$TODO_FILE" <<'PYEOF'
import sys, json, re, os

filepath = sys.argv[1] if len(sys.argv) > 1 else ""
tasks = []

if not filepath or not os.path.exists(filepath):
    print(json.dumps({"tasks": [], "error": "todo.md not found"}))
    sys.exit(0)

with open(filepath, encoding="utf-8") as f:
    lines = f.readlines()

current_category = "Uncategorized"
current_sub_category = ""

for line in lines:
    stripped = line.rstrip()

    # ## Header = category
    if stripped.startswith("## "):
        current_category = stripped[3:].strip()
        current_sub_category = ""
        continue

    # ### Sub-header = sub-category / task group name
    if stripped.startswith("### "):
        current_sub_category = stripped[4:].strip()
        continue

    # Checkbox lines
    m = re.match(r'\s*-\s+\[([ xX])\]\s+(.*)', stripped)
    if not m:
        continue

    done = m.group(1).lower() == 'x'
    text = m.group(2).strip()

    # Remove trailing ✅ etc
    text = re.sub(r'\s*✅\s*$', '', text).strip()

    # Priority detection: P1 / P2 / P3 / AUTO anywhere in text or sub_category
    priority = None
    for src in [text, current_sub_category]:
        pm = re.search(r'\b(P[123]|AUTO)\b', src, re.IGNORECASE)
        if pm:
            priority = pm.group(1).upper()
            break

    # Estimate: ~Xh or ~X小時
    estimate = None
    em = re.search(r'~(\d+\.?\d*)\s*h(?:r|ours?)?', text, re.IGNORECASE)
    if em:
        estimate = f"~{em.group(1)}h"

    # Blocked detection
    blocked = bool(re.search(r'\[blocked\]|\[阻塞\]|blocked:', text, re.IGNORECASE))

    # Category: prefer sub_category, else category
    display_cat = current_sub_category if current_sub_category else current_category

    tasks.append({
        "text": text,
        "done": done,
        "category": display_cat,
        "raw_category": current_category,
        "priority": priority,
        "estimate": estimate,
        "blocked": blocked
    })

print(json.dumps({"tasks": tasks, "error": None}))
PYEOF
)

# ─── Parse progress-log.md with Python ───────────────────────────────────────
PROGRESS_JSON=$(python3 - "$PROGRESS_FILE" <<'PYEOF'
import sys, json, re, os

filepath = sys.argv[1] if len(sys.argv) > 1 else ""
entries = []

if not filepath or not os.path.exists(filepath):
    print(json.dumps({"entries": [], "error": "progress-log.md not found"}))
    sys.exit(0)

with open(filepath, encoding="utf-8") as f:
    content = f.read()

# Split on ## YYYY-MM-DD HH:MM headers
sections = re.split(r'^(## \d{4}-\d{2}-\d{2}[^\n]*)', content, flags=re.MULTILINE)

i = 1
while i < len(sections) - 1:
    header = sections[i].strip()
    body = sections[i+1].strip() if i+1 < len(sections) else ""
    i += 2

    # Parse timestamp and title from header
    # ## 2026-03-22 22:30 — Memory Dashboard 完成 ✅
    hm = re.match(r'## (\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})(?:\s+[—–-]+\s*(.*))?', header)
    if not hm:
        continue

    date_str = hm.group(1)
    time_str = hm.group(2)
    title = (hm.group(3) or "").strip()

    # Collect bullet points from body
    bullets = []
    for line in body.split('\n'):
        bl = line.strip()
        if bl.startswith('- '):
            bullets.append(bl[2:].strip())

    # Detect type from title/body
    combined = (title + " " + body).lower()
    etype = "update"
    if re.search(r'完成|done|finish|✅|通過|success', combined):
        etype = "completion"
    elif re.search(r'開始|start|begin|啟動|初始化', combined):
        etype = "start"

    entries.append({
        "date": date_str,
        "time": time_str,
        "timestamp": f"{date_str} {time_str}",
        "title": title,
        "bullets": bullets,
        "type": etype
    })

# Most recent first
entries.sort(key=lambda e: e["timestamp"], reverse=True)
print(json.dumps({"entries": entries, "error": None}))
PYEOF
)

# ─── Compute summary stats ────────────────────────────────────────────────────
STATS_JSON=$(python3 - "$TASKS_JSON" "$PROGRESS_JSON" <<'PYEOF'
import sys, json

tasks_data = json.loads(sys.argv[1])
progress_data = json.loads(sys.argv[2])

tasks = tasks_data.get("tasks", [])
entries = progress_data.get("entries", [])

total = len(tasks)
done = sum(1 for t in tasks if t["done"])
pending = total - done
blocked = sum(1 for t in tasks if t.get("blocked"))
in_progress = pending - blocked  # rough
completion_pct = round(done / total * 100, 1) if total > 0 else 0

last_activity = entries[0]["timestamp"] if entries else "N/A"

print(json.dumps({
    "total": total,
    "done": done,
    "pending": pending,
    "blocked": blocked,
    "in_progress": in_progress,
    "completion_pct": completion_pct,
    "last_activity": last_activity,
    "progress_count": len(entries)
}))
PYEOF
)

# ─── Generate HTML ────────────────────────────────────────────────────────────
python3 - "$TASKS_JSON" "$PROGRESS_JSON" "$STATS_JSON" "$TIMESTAMP" "$OUTPUT_FILE" <<'PYEOF'
import sys, json, html

tasks_data   = json.loads(sys.argv[1])
progress_data = json.loads(sys.argv[2])
stats        = json.loads(sys.argv[3])
timestamp    = sys.argv[4]
output_file  = sys.argv[5]

tasks   = tasks_data.get("tasks", [])
entries = progress_data.get("entries", [])

def esc(s):
    return html.escape(str(s)) if s else ""

# ── Build task cards ──────────────────────────────────────────────────────────
def build_task_card(task):
    status_class = "done" if task["done"] else ("blocked" if task.get("blocked") else "pending")
    status_labels = {
        "done":    {"en": "Done",    "zh": "完成"},
        "pending": {"en": "Pending", "zh": "待辦"},
        "blocked": {"en": "Blocked", "zh": "阻塞"},
    }
    sl = status_labels.get(status_class, {"en": "Pending", "zh": "待辦"})

    priority_html = ""
    if task.get("priority"):
        p = esc(task["priority"])
        cls = "p1" if p == "P1" else ("p2" if p == "P2" else ("p3" if p == "P3" else "auto"))
        priority_html = f'<span class="tag priority-{cls}">{p}</span>'

    estimate_html = ""
    if task.get("estimate"):
        estimate_html = f'<span class="tag estimate">{esc(task["estimate"])}</span>'

    cat_html = f'<span class="tag category">{esc(task["category"])}</span>'

    return f'''<div class="task-card {status_class}">
  <div class="task-header">
    <span class="status-badge {status_class}">
      <span class="en">{sl["en"]}</span><span class="zh">{sl["zh"]}</span>
    </span>
    <div class="task-tags">
      {priority_html}
      {estimate_html}
      {cat_html}
    </div>
  </div>
  <div class="task-text">{esc(task["text"])}</div>
</div>'''

# Separate tasks into columns
done_tasks     = [t for t in tasks if t["done"]]
blocked_tasks  = [t for t in tasks if not t["done"] and t.get("blocked")]
pending_tasks  = [t for t in tasks if not t["done"] and not t.get("blocked")]

done_cards    = "\n".join(build_task_card(t) for t in done_tasks)    or '<p class="empty"><span class="en">No completed tasks</span><span class="zh">無完成任務</span></p>'
blocked_cards = "\n".join(build_task_card(t) for t in blocked_tasks) or '<p class="empty"><span class="en">No blocked tasks</span><span class="zh">無阻塞任務</span></p>'
pending_cards = "\n".join(build_task_card(t) for t in pending_tasks) or '<p class="empty"><span class="en">No pending tasks</span><span class="zh">無待辦任務</span></p>'

# ── Build timeline ────────────────────────────────────────────────────────────
def build_timeline_entry(entry):
    dot_class = entry.get("type", "update")
    bullets_html = ""
    if entry.get("bullets"):
        items = "".join(f"<li>{esc(b)}</li>" for b in entry["bullets"])
        bullets_html = f"<ul class='timeline-bullets'>{items}</ul>"
    return f'''<div class="timeline-item">
  <div class="timeline-left">
    <div class="timeline-date">{esc(entry["date"])}</div>
    <div class="timeline-time">{esc(entry["time"])}</div>
  </div>
  <div class="timeline-dot {dot_class}"></div>
  <div class="timeline-right">
    <div class="timeline-title">{esc(entry["title"])}</div>
    {bullets_html}
  </div>
</div>'''

timeline_html = "\n".join(build_timeline_entry(e) for e in entries) or \
    '<p class="empty"><span class="en">No progress entries</span><span class="zh">無進度記錄</span></p>'

# ── Error notices ─────────────────────────────────────────────────────────────
todo_error_html = ""
if tasks_data.get("error"):
    todo_error_html = f'<div class="error-notice">⚠️ {esc(tasks_data["error"])}</div>'

progress_error_html = ""
if progress_data.get("error"):
    progress_error_html = f'<div class="error-notice">⚠️ {esc(progress_data["error"])}</div>'

# ── HTML ──────────────────────────────────────────────────────────────────────
html_content = f"""<!DOCTYPE html>
<html lang="zh-TW">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Task Management Center — OpenClaw</title>
<style>
  :root {{
    --bg: #0f172a;
    --card: #1e293b;
    --card2: #263147;
    --border: #334155;
    --accent: #6366f1;
    --accent2: #818cf8;
    --text: #e2e8f0;
    --muted: #94a3b8;
    --green: #22c55e;
    --blue: #3b82f6;
    --amber: #f59e0b;
    --red: #ef4444;
    --purple: #a855f7;
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    min-height: 100vh;
    padding: 0 0 40px;
  }}
  @keyframes fadeInUp {{
    from {{ opacity: 0; transform: translateY(20px); }}
    to   {{ opacity: 1; transform: translateY(0); }}
  }}
  .fade-in {{ animation: fadeInUp 0.4s ease both; }}

  /* ── Header ── */
  .header {{
    background: linear-gradient(135deg, #1e293b 0%, #0f1f3a 100%);
    border-bottom: 1px solid var(--border);
    padding: 24px 32px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 16px;
  }}
  .header-left h1 {{ font-size: 1.6rem; font-weight: 700; }}
  .header-left .subtitle {{ color: var(--muted); font-size: 0.9rem; margin-top: 4px; }}
  .header-right {{ display: flex; gap: 12px; align-items: center; }}

  .lang-btn {{
    background: var(--card2);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 6px 14px;
    border-radius: 8px;
    cursor: pointer;
    font-size: 0.85rem;
    transition: all 0.2s;
  }}
  .lang-btn:hover {{ background: var(--accent); border-color: var(--accent); }}

  /* ── Stats Bar ── */
  .stats-bar {{
    background: var(--card);
    border-bottom: 1px solid var(--border);
    padding: 12px 32px;
    display: flex;
    gap: 24px;
    flex-wrap: wrap;
    align-items: center;
    font-size: 0.85rem;
  }}
  .stat-item {{ display: flex; gap: 6px; align-items: center; }}
  .stat-label {{ color: var(--muted); }}
  .stat-value {{ font-weight: 600; }}
  .stat-value.green {{ color: var(--green); }}
  .stat-value.blue  {{ color: var(--blue); }}
  .stat-value.amber {{ color: var(--amber); }}
  .stat-value.red   {{ color: var(--red); }}
  .stat-divider {{ color: var(--border); }}
  .refresh-info {{ margin-left: auto; color: var(--muted); font-size: 0.8rem; }}

  /* ── Main content ── */
  .main {{ padding: 32px; max-width: 1400px; margin: 0 auto; }}
  .section {{ margin-bottom: 40px; }}
  .section-title {{
    font-size: 1.1rem; font-weight: 700;
    margin-bottom: 16px;
    padding-bottom: 8px;
    border-bottom: 2px solid var(--accent);
    display: inline-block;
  }}

  /* ── Summary Cards ── */
  .summary-grid {{
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
    gap: 16px;
    margin-bottom: 40px;
  }}
  .summary-card {{
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px;
    text-align: center;
    animation: fadeInUp 0.4s ease both;
  }}
  .summary-card .val {{
    font-size: 2rem;
    font-weight: 800;
    line-height: 1;
    margin-bottom: 6px;
  }}
  .summary-card .lbl {{
    font-size: 0.78rem;
    color: var(--muted);
    line-height: 1.3;
  }}
  .summary-card.green-border {{ border-color: var(--green); }}
  .summary-card.blue-border  {{ border-color: var(--blue); }}
  .summary-card.amber-border {{ border-color: var(--amber); }}
  .summary-card.red-border   {{ border-color: var(--red); }}
  .summary-card.purple-border {{ border-color: var(--purple); }}

  /* ── Kanban ── */
  .kanban {{
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 20px;
  }}
  @media (max-width: 900px) {{
    .kanban {{ grid-template-columns: 1fr; }}
  }}
  .kanban-col {{
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    overflow: hidden;
  }}
  .kanban-col-header {{
    padding: 12px 16px;
    font-weight: 700;
    font-size: 0.9rem;
    display: flex;
    align-items: center;
    gap: 8px;
  }}
  .kanban-col-header.pending-h {{ background: rgba(245,158,11,0.15); border-bottom: 2px solid var(--amber); }}
  .kanban-col-header.done-h    {{ background: rgba(34,197,94,0.15);  border-bottom: 2px solid var(--green); }}
  .kanban-col-header.blocked-h {{ background: rgba(239,68,68,0.15);  border-bottom: 2px solid var(--red); }}
  .kanban-col-body {{ padding: 12px; display: flex; flex-direction: column; gap: 10px; }}

  /* ── Task Cards ── */
  .task-card {{
    background: var(--card2);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 12px 14px;
    border-left: 4px solid var(--border);
    transition: transform 0.15s;
    animation: fadeInUp 0.4s ease both;
  }}
  .task-card:hover {{ transform: translateY(-2px); }}
  .task-card.done    {{ border-left-color: var(--green); }}
  .task-card.pending {{ border-left-color: var(--amber); }}
  .task-card.blocked {{ border-left-color: var(--red); }}
  .task-header {{ display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-bottom: 8px; }}
  .task-tags {{ display: flex; gap: 4px; flex-wrap: wrap; margin-left: auto; }}
  .task-text {{ font-size: 0.88rem; line-height: 1.5; color: var(--text); }}
  .task-card.done .task-text {{ color: var(--muted); text-decoration: line-through; }}

  /* ── Status Badge ── */
  .status-badge {{
    font-size: 0.72rem;
    font-weight: 700;
    padding: 2px 8px;
    border-radius: 20px;
    white-space: nowrap;
  }}
  .status-badge.done    {{ background: rgba(34,197,94,0.2);  color: var(--green); }}
  .status-badge.pending {{ background: rgba(245,158,11,0.2); color: var(--amber); }}
  .status-badge.blocked {{ background: rgba(239,68,68,0.2);  color: var(--red); }}

  /* ── Tags ── */
  .tag {{
    font-size: 0.68rem;
    font-weight: 600;
    padding: 1px 6px;
    border-radius: 6px;
    white-space: nowrap;
  }}
  .tag.category      {{ background: rgba(99,102,241,0.2); color: var(--accent2); }}
  .tag.estimate      {{ background: rgba(59,130,246,0.2); color: var(--blue); }}
  .tag.priority-p1   {{ background: rgba(239,68,68,0.25); color: var(--red); }}
  .tag.priority-p2   {{ background: rgba(245,158,11,0.25); color: var(--amber); }}
  .tag.priority-p3   {{ background: rgba(34,197,94,0.2); color: var(--green); }}
  .tag.priority-auto {{ background: rgba(168,85,247,0.2); color: var(--purple); }}

  /* ── Timeline ── */
  .timeline {{ display: flex; flex-direction: column; gap: 0; }}
  .timeline-item {{
    display: grid;
    grid-template-columns: 130px 20px 1fr;
    gap: 16px;
    align-items: start;
    padding: 0 0 24px;
    animation: fadeInUp 0.4s ease both;
  }}
  .timeline-left {{ text-align: right; padding-top: 4px; }}
  .timeline-date {{ font-size: 0.78rem; font-weight: 700; color: var(--text); }}
  .timeline-time {{ font-size: 0.72rem; color: var(--muted); }}
  .timeline-dot {{
    width: 14px; height: 14px;
    border-radius: 50%;
    margin-top: 6px;
    flex-shrink: 0;
    border: 2px solid var(--bg);
    box-shadow: 0 0 0 3px var(--border);
  }}
  .timeline-dot.completion {{ background: var(--green); box-shadow: 0 0 0 3px rgba(34,197,94,0.3); }}
  .timeline-dot.start      {{ background: var(--blue);  box-shadow: 0 0 0 3px rgba(59,130,246,0.3); }}
  .timeline-dot.update     {{ background: var(--amber); box-shadow: 0 0 0 3px rgba(245,158,11,0.3); }}
  .timeline-right {{
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 12px 16px;
  }}
  .timeline-title {{ font-size: 0.9rem; font-weight: 600; margin-bottom: 6px; }}
  .timeline-bullets {{ padding-left: 18px; margin-top: 6px; }}
  .timeline-bullets li {{ font-size: 0.82rem; color: var(--muted); margin-bottom: 3px; line-height: 1.5; }}

  @media (max-width: 600px) {{
    .header {{ padding: 16px; }}
    .main {{ padding: 16px; }}
    .stats-bar {{ padding: 10px 16px; }}
    .timeline-item {{ grid-template-columns: 80px 16px 1fr; gap: 10px; }}
  }}

  /* ── i18n ── */
  .en, .zh {{ display: none; }}
  body.lang-en .en {{ display: inline; }}
  body.lang-zh .zh {{ display: inline; }}
  body.lang-en .en-block {{ display: block; }}
  body.lang-zh .zh-block {{ display: block; }}

  .error-notice {{
    background: rgba(239,68,68,0.1);
    border: 1px solid rgba(239,68,68,0.3);
    border-radius: 8px;
    padding: 12px 16px;
    font-size: 0.85rem;
    color: var(--red);
    margin-bottom: 16px;
  }}
  .empty {{ color: var(--muted); font-size: 0.85rem; padding: 12px; text-align: center; }}
  .col-count {{
    background: rgba(255,255,255,0.1);
    border-radius: 20px;
    padding: 1px 7px;
    font-size: 0.78rem;
    font-weight: 700;
  }}
</style>
</head>
<body class="lang-zh">

<!-- ── Header ── -->
<div class="header fade-in">
  <div class="header-left">
    <h1>📋 <span class="en">Task Management Center</span><span class="zh">任務管理中心</span></h1>
    <div class="subtitle">OpenClaw · Scott#4</div>
  </div>
  <div class="header-right">
    <button class="lang-btn" onclick="toggleLang()">EN / 中文</button>
  </div>
</div>

<!-- ── Stats Bar ── -->
<div class="stats-bar fade-in">
  <div class="stat-item">
    <span class="stat-label"><span class="en">Total</span><span class="zh">總計</span></span>
    <span class="stat-value">{stats["total"]}</span>
  </div>
  <span class="stat-divider">|</span>
  <div class="stat-item">
    <span class="stat-label"><span class="en">Done</span><span class="zh">完成</span></span>
    <span class="stat-value green">{stats["done"]}</span>
  </div>
  <span class="stat-divider">|</span>
  <div class="stat-item">
    <span class="stat-label"><span class="en">Pending</span><span class="zh">待辦</span></span>
    <span class="stat-value amber">{stats["pending"]}</span>
  </div>
  <span class="stat-divider">|</span>
  <div class="stat-item">
    <span class="stat-label"><span class="en">Blocked</span><span class="zh">阻塞</span></span>
    <span class="stat-value red">{stats["blocked"]}</span>
  </div>
  <span class="stat-divider">|</span>
  <div class="stat-item">
    <span class="stat-label"><span class="en">Rate</span><span class="zh">完成率</span></span>
    <span class="stat-value blue">{stats["completion_pct"]}%</span>
  </div>
  <div class="refresh-info">
    <span class="en">Generated</span><span class="zh">生成於</span>: {timestamp} ·
    <span class="en">Auto-refresh every 5 min</span><span class="zh">每 5 分鐘自動更新</span>
  </div>
</div>

<!-- ── Main ── -->
<div class="main">

  <!-- Summary Stats -->
  <div class="section fade-in">
    <div class="section-title">
      📊 <span class="en">Summary</span><span class="zh">統計摘要</span>
    </div>
    <div class="summary-grid">
      <div class="summary-card" style="animation-delay:0.05s">
        <div class="val" style="color:var(--text)">{stats["total"]}</div>
        <div class="lbl"><span class="en">Total Tasks</span><span class="zh">總任務數</span></div>
      </div>
      <div class="summary-card green-border" style="animation-delay:0.1s">
        <div class="val" style="color:var(--green)">{stats["done"]}</div>
        <div class="lbl"><span class="en">Completed</span><span class="zh">已完成</span></div>
      </div>
      <div class="summary-card amber-border" style="animation-delay:0.15s">
        <div class="val" style="color:var(--amber)">{stats["pending"]}</div>
        <div class="lbl"><span class="en">Pending</span><span class="zh">待辦</span></div>
      </div>
      <div class="summary-card red-border" style="animation-delay:0.2s">
        <div class="val" style="color:var(--red)">{stats["blocked"]}</div>
        <div class="lbl"><span class="en">Blocked</span><span class="zh">阻塞</span></div>
      </div>
      <div class="summary-card blue-border" style="animation-delay:0.25s">
        <div class="val" style="color:var(--blue)">{stats["completion_pct"]}%</div>
        <div class="lbl"><span class="en">Completion Rate</span><span class="zh">完成率</span></div>
      </div>
      <div class="summary-card purple-border" style="animation-delay:0.3s">
        <div class="val" style="color:var(--purple)">{stats["progress_count"]}</div>
        <div class="lbl"><span class="en">Progress Entries</span><span class="zh">進度條目</span></div>
      </div>
    </div>
    <div style="font-size:0.8rem;color:var(--muted);margin-top:-24px">
      <span class="en">Last activity:</span><span class="zh">最後活動：</span>
      <strong>{esc(stats["last_activity"])}</strong>
    </div>
  </div>

  <!-- Task Board -->
  <div class="section fade-in" style="animation-delay:0.1s">
    <div class="section-title">
      📌 <span class="en">Task Board</span><span class="zh">任務看板</span>
    </div>
    {todo_error_html}
    <div class="kanban">
      <div class="kanban-col">
        <div class="kanban-col-header pending-h">
          🟡 <span class="en">In Progress / Pending</span><span class="zh">進行中 / 待辦</span>
          <span class="col-count">{stats["pending"]}</span>
        </div>
        <div class="kanban-col-body">{pending_cards}</div>
      </div>
      <div class="kanban-col">
        <div class="kanban-col-header done-h">
          ✅ <span class="en">Completed</span><span class="zh">已完成</span>
          <span class="col-count">{stats["done"]}</span>
        </div>
        <div class="kanban-col-body">{done_cards}</div>
      </div>
      <div class="kanban-col">
        <div class="kanban-col-header blocked-h">
          🔴 <span class="en">Blocked</span><span class="zh">阻塞</span>
          <span class="col-count">{stats["blocked"]}</span>
        </div>
        <div class="kanban-col-body">{blocked_cards}</div>
      </div>
    </div>
  </div>

  <!-- Progress Timeline -->
  <div class="section fade-in" style="animation-delay:0.2s">
    <div class="section-title">
      📅 <span class="en">Progress Timeline</span><span class="zh">進度時間軸</span>
    </div>
    {progress_error_html}
    <div class="timeline">{timeline_html}</div>
  </div>

</div>

<script>
  // i18n toggle
  function toggleLang() {{
    const body = document.body;
    body.classList.toggle('lang-en');
    body.classList.toggle('lang-zh');
  }}

  // Auto-refresh every 5 minutes
  setTimeout(() => location.reload(), 5 * 60 * 1000);

  // Stagger card animations
  document.querySelectorAll('.task-card').forEach((el, i) => {{
    el.style.animationDelay = (i * 0.04) + 's';
  }});
  document.querySelectorAll('.timeline-item').forEach((el, i) => {{
    el.style.animationDelay = (i * 0.05) + 's';
  }});
</script>
</body>
</html>"""

with open(output_file, "w", encoding="utf-8") as f:
    f.write(html_content)

print(f"OK: {output_file}")
PYEOF

echo "✅ task-dashboard.html generated → $OUTPUT_FILE"
echo "   Generated at: $TIMESTAMP"
