#!/bin/bash
# Final 5A+ × 10 Rounds — Comprehensive Five-Layer Memory Test
# Fixed: consistent dataset names, proper JSON parsing, accurate grep

ROUNDS=10
PASS=0; FAIL=0; TOTAL=0

test_result() {
    TOTAL=$((TOTAL+1))
    if [ "$1" = "PASS" ]; then
        PASS=$((PASS+1))
        echo "  ✅ [$TOTAL] $2"
    else
        FAIL=$((FAIL+1))
        echo "  ❌ [$TOTAL] $2 — $3"
    fi
}

echo "══════════════════════════════════════════════════════════"
echo "  FINAL 5A+ Comprehensive Test — $ROUNDS Rounds × 5 Layers"
echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "══════════════════════════════════════════════════════════"

# Pre-auth Cognee (once)
curl -s -X POST http://10.10.10.66:8766/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"scott@openclaw.ai","password":"openclaw2026"}' 2>/dev/null > /dev/null
AT=$(curl -s -X POST http://10.10.10.66:8766/api/v1/auth/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d 'username=scott@openclaw.ai&password=openclaw2026' | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

# Timing arrays
declare -a T_L0 T_L1 T_L2 T_L3 T_MW T_MS T_CA T_CS T_XGW

for R in $(seq 1 $ROUNDS); do
    echo ""
    echo "━━━ Round $R/$ROUNDS ━━━"

    # ── L0: Markdown files ──
    S=$(python3 -c "import time;print(int(time.time()*1000))")
    L0_OK=true
    for f in AGENTS.md SOUL.md IDENTITY.md USER.md TOOLS.md; do
        [ -f ~/.openclaw/workspace/$f ] || L0_OK=false
    done
    grep -q "Happy" ~/.openclaw/workspace/SOUL.md || L0_OK=false
    grep -q "Scott" ~/.openclaw/workspace/USER.md || L0_OK=false
    E=$(python3 -c "import time;print(int(time.time()*1000))")
    T=$((E-S)); T_L0+=($T)
    $L0_OK && test_result "PASS" "L0 files+content: ${T}ms" || test_result "FAIL" "L0" "missing"

    # ── L1: lossless-claw config ──
    S=$(python3 -c "import time;print(int(time.time()*1000))")
    L1_OK=false
    [ -f ~/.openclaw/lcm.db ] && \
    python3 -c "import json;c=json.load(open('$HOME/.openclaw/openclaw.json'));m=c['plugins']['entries']['lossless-claw']['config']['summaryModel'];exit(0 if 'MiniMax' in m else 1)" 2>/dev/null && \
    openclaw status 2>&1 | grep -q '\[lcm\] Plugin loaded' && L1_OK=true
    E=$(python3 -c "import time;print(int(time.time()*1000))")
    T=$((E-S)); T_L1+=($T)
    $L1_OK && test_result "PASS" "L1 db+config+plugin: ${T}ms" || test_result "FAIL" "L1" "check"

    # ── L2: LanceDB Pro ──
    S=$(python3 -c "import time;print(int(time.time()*1000))")
    L2_OK=false
    L2F=$(find ~/.openclaw-data/memory-lancedb -name "*.lance" 2>/dev/null | wc -l | tr -d ' ')
    [ "$L2F" -gt 0 ] && \
    openclaw status 2>&1 | grep -q 'memory-lancedb-pro.*registered' && \
    python3 -c "import json;c=json.load(open('$HOME/.openclaw/openclaw.json'));r=c['plugins']['entries']['memory-lancedb-pro']['config']['retrieval'];exit(0 if r['recencyHalfLifeDays']==14 and r['recencyWeight']==0.25 and r['rerank']=='cross-encoder' else 1)" 2>/dev/null && \
    L2_OK=true
    E=$(python3 -c "import time;print(int(time.time()*1000))")
    T=$((E-S)); T_L2+=($T)
    $L2_OK && test_result "PASS" "L2 vectors+config+rerank: ${T}ms" || test_result "FAIL" "L2" "check"

    # ── L3: QMD ──
    S=$(python3 -c "import time;print(int(time.time()*1000))")
    QMD_DB=$(find ~/.openclaw -name "index.sqlite" -path "*/qmd/*" 2>/dev/null | head -1)
    L3_OK=false
    if [ -n "$QMD_DB" ]; then
        QC=$(sqlite3 "$QMD_DB" "SELECT COUNT(*) FROM documents;" 2>/dev/null || echo "0")
        [ "$QC" -gt 0 ] && L3_OK=true
    fi
    E=$(python3 -c "import time;print(int(time.time()*1000))")
    T=$((E-S)); T_L3+=($T)
    $L3_OK && test_result "PASS" "L3 QMD ${QC} docs: ${T}ms" || test_result "FAIL" "L3" "empty"

    # ── L2+: MemOS Write ──
    S=$(python3 -c "import time;print(int(time.time()*1000))")
    MW_R=$(curl -s --max-time 60 -X POST http://10.10.10.66:8765/product/add \
      -H "Content-Type: application/json" \
      -d "{\"user_id\":\"final5a\",\"async_mode\":\"sync\",\"messages\":[{\"role\":\"user\",\"content\":\"Final 5A round $R at $(date +%s)\"},{\"role\":\"assistant\",\"content\":\"Verified round $R\"}]}" 2>&1)
    E=$(python3 -c "import time;print(int(time.time()*1000))")
    T=$((E-S)); T_MW+=($T)
    echo "$MW_R" | python3 -c "import json,sys;d=json.loads(sys.stdin.read().replace('\n','\\\\n'));exit(0 if d.get('code')==200 else 1)" 2>/dev/null && \
        test_result "PASS" "L2+ MemOS write: ${T}ms" || test_result "FAIL" "L2+ write" "${T}ms"

    # ── L2+: MemOS Search ──
    S=$(python3 -c "import time;print(int(time.time()*1000))")
    MS_R=$(curl -s --max-time 15 -X POST http://10.10.10.66:8765/product/search \
      -H "Content-Type: application/json" \
      -d "{\"query\":\"Final 5A round $R\",\"user_id\":\"final5a\",\"top_k\":3}" 2>&1)
    E=$(python3 -c "import time;print(int(time.time()*1000))")
    T=$((E-S)); T_MS+=($T)
    echo "$MS_R" | python3 -c "import json,sys;d=json.loads(sys.stdin.read().replace('\n','\\\\n'));exit(0 if d.get('code')==200 else 1)" 2>/dev/null && \
        test_result "PASS" "L2+ MemOS search: ${T}ms" || test_result "FAIL" "L2+ search" "${T}ms"

    # ── L4: Cognee Add (same dataset) ──
    echo "Final 5A round $R verification data" > /tmp/final5a-$R.txt
    S=$(python3 -c "import time;print(int(time.time()*1000))")
    CA_R=$(curl -s --max-time 60 -X POST http://10.10.10.66:8766/api/v1/add \
      -H "Authorization: Bearer $AT" \
      -F "data=@/tmp/final5a-$R.txt" \
      -F "datasetName=final5a-unified" 2>&1)
    E=$(python3 -c "import time;print(int(time.time()*1000))")
    T=$((E-S)); T_CA+=($T)
    echo "$CA_R" | grep -q "PipelineRunCompleted" && \
        test_result "PASS" "L4 Cognee add: ${T}ms" || test_result "FAIL" "L4 add" "${T}ms"

    # ── L4: Cognee Search ──
    S=$(python3 -c "import time;print(int(time.time()*1000))")
    CS_R=$(curl -s --max-time 15 -X POST http://10.10.10.66:8766/api/v1/search \
      -H "Authorization: Bearer $AT" \
      -H "Content-Type: application/json" \
      -d '{"query":"ALL MINIMAX Ultra plan","searchType":"CHUNKS"}' 2>&1)
    E=$(python3 -c "import time;print(int(time.time()*1000))")
    T=$((E-S)); T_CS+=($T)
    echo "$CS_R" | grep -q '"text"' && \
        test_result "PASS" "L4 Cognee search: ${T}ms" || test_result "FAIL" "L4 search" "${T}ms"

    # ── Cross-layer: Gateway + Containers ──
    S=$(python3 -c "import time;print(int(time.time()*1000))")
    XGW_OK=true
    openclaw status 2>&1 | grep -q '0 critical' || XGW_OK=false
    E=$(python3 -c "import time;print(int(time.time()*1000))")
    T=$((E-S)); T_XGW+=($T)
    $XGW_OK && test_result "PASS" "X gateway 0 critical: ${T}ms" || test_result "FAIL" "X gateway" "critical>0"
done

# ──────── Container check (once) ──────
echo ""
echo "━━━ NAS Container Check ━━━"
NAS_UP=$(ssh -o ConnectTimeout=5 openclaw@10.10.10.66 "/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker ps --format '{{.Names}}:{{.Status}}'" 2>&1)
for c in oc-cognee-api oc-memos-api oc-neo4j oc-qdrant; do
    echo "$NAS_UP" | grep -q "$c" && test_result "PASS" "$c running" || test_result "FAIL" "$c" "down"
done

# Slot + no-dup check
SLOT=$(python3 -c "import json;c=json.load(open('$HOME/.openclaw/openclaw.json'));print(c['plugins'].get('slots',{}).get('memory','?'))" 2>/dev/null)
[ "$SLOT" = "memory-lancedb-pro" ] && test_result "PASS" "Memory slot: $SLOT (no conflict)" || test_result "FAIL" "Slot: $SLOT"

COGNEE_KIND=$(python3 -c "import json;m=json.load(open('$HOME/.openclaw/extensions/cognee-sidecar-openclaw/openclaw.plugin.json'));print(m.get('kind','NONE'))" 2>/dev/null)
[ "$COGNEE_KIND" = "NONE" ] && test_result "PASS" "Cognee sidecar: no slot collision" || test_result "FAIL" "kind=$COGNEE_KIND"

# ──────── STATS ──────
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  PERFORMANCE STATISTICS ($ROUNDS rounds)"
echo "══════════════════════════════════════════════════════════"
echo ""

pystats() {
    python3 -c "
vals = [int(x) for x in '$*'.split() if x]
if not vals: print('N/A'); exit()
avg=sum(vals)//len(vals); mn=min(vals); mx=max(vals)
s=sorted(vals); p50=s[len(s)//2]; p95=s[int(len(s)*0.95)]
std=int((sum((v-avg)**2 for v in vals)/len(vals))**0.5)
print(f'| avg={avg}ms | min={mn}ms | max={mx}ms | p50={p50}ms | p95={p95}ms | std={std}ms |')
"
}

echo "| Layer | Pass | Stats |"
echo "|-------|------|-------|"
echo -n "| L0 files | $PASS | "; pystats ${T_L0[@]}
echo -n "| L1 config | - | "; pystats ${T_L1[@]}
echo -n "| L2 vectors | - | "; pystats ${T_L2[@]}
echo -n "| L3 QMD | - | "; pystats ${T_L3[@]}
echo -n "| L2+ write | - | "; pystats ${T_MW[@]}
echo -n "| L2+ search | - | "; pystats ${T_MS[@]}
echo -n "| L4 add | - | "; pystats ${T_CA[@]}
echo -n "| L4 search | - | "; pystats ${T_CS[@]}
echo -n "| X gateway | - | "; pystats ${T_XGW[@]}

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  FINAL RESULTS: $PASS PASS / $FAIL FAIL / $TOTAL TOTAL"
RATE=$((PASS * 100 / TOTAL))
echo "  Pass Rate: ${RATE}%"
if [ $FAIL -eq 0 ]; then
    echo "  🏆🏆🏆 5A+ CERTIFIED — PERFECT SCORE 🏆🏆🏆"
elif [ $FAIL -le 3 ]; then
    echo "  ⭐ 5A CERTIFIED — $FAIL minor issues"
else
    echo "  ⚠️ NEEDS ATTENTION — $FAIL failures"
fi
echo "  Timestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "══════════════════════════════════════════════════════════"
