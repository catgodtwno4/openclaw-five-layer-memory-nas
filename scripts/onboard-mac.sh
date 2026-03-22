#!/bin/bash
set -euo pipefail

# ============================================
# OpenClaw Mac Mini → NAS 記憶棧接入腳本
# ============================================

NAS_IP="${1:-}"
MACHINE_ID="${2:-$(hostname | tr '[:upper:]' '[:lower:]' | tr ' #' '-')}"

if [ -z "$NAS_IP" ]; then
  echo "Usage: bash onboard-mac.sh <NAS_IP> [machine_id]"
  echo "Example: bash onboard-mac.sh 10.10.10.66 scott4"
  exit 1
fi

echo "============================================"
echo "  OpenClaw → NAS Memory Stack Onboarding"
echo "  NAS: $NAS_IP"
echo "  Machine: $MACHINE_ID"
echo "============================================"
echo ""

# Step 1: Network check
echo "=== Step 1: Network Check ==="
FAIL=0
for port_name in "8765:MemOS" "8766:Cognee" "7474:Neo4j" "6333:Qdrant"; do
  PORT="${port_name%%:*}"
  NAME="${port_name##*:}"
  if curl -sf --connect-timeout 5 "http://$NAS_IP:$PORT" > /dev/null 2>&1 || \
     curl -sf --connect-timeout 5 "http://$NAS_IP:$PORT/docs" > /dev/null 2>&1; then
    echo "  ✅ $NAME (:$PORT)"
  else
    echo "  ❌ $NAME (:$PORT) — 不可達！"
    FAIL=1
  fi
done

if [ "$FAIL" = "1" ]; then
  echo ""
  echo "⚠️ 部分服務不可達，請檢查 NAS 是否運行中、防火牆是否開放端口。"
  echo "繼續嗎？(y/N)"
  read -r ans
  [ "$ans" != "y" ] && exit 1
fi

# Step 2: Install Cognee plugin
echo ""
echo "=== Step 2: Install Cognee Plugin ==="
if [ -d "$HOME/.openclaw/extensions/cognee-openclaw" ]; then
  echo "  cognee-openclaw 已安裝，跳過"
else
  echo "  安裝中..."
  openclaw plugins install @cognee/cognee-openclaw 2>&1 | tail -3
fi

# Step 3: Create sidecar clone
echo ""
echo "=== Step 3: Create Sidecar Clone ==="
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$HOME/.openclaw/extensions/cognee-sidecar-openclaw" ]; then
  echo "  sidecar 已存在，跳過（用 --force 重建）"
else
  python3 "$SCRIPT_DIR/make_cognee_sidecar_clone.py" --force
fi

# Step 4: Update openclaw.json
echo ""
echo "=== Step 4: Update openclaw.json ==="
CONFIG="$HOME/.openclaw/openclaw.json"

python3 -c "
import json
with open('$CONFIG') as f:
    config = json.load(f)

plugins = config.setdefault('plugins', {})
entries = plugins.setdefault('entries', {})
allow = plugins.setdefault('allow', [])

# Ensure LanceDB Pro owns memory slot
plugins['slots'] = plugins.get('slots', {})
plugins['slots']['memory'] = 'memory-lancedb-pro'

# Allow sidecar
if 'cognee-sidecar-openclaw' not in allow:
    allow.append('cognee-sidecar-openclaw')

# Disable original cognee
entries['cognee-openclaw'] = {'enabled': False}

# Enable sidecar
entries['cognee-sidecar-openclaw'] = {
    'enabled': True,
    'config': {
        'baseUrl': 'http://$NAS_IP:8766',
        'datasetName': 'openclaw-$MACHINE_ID-v1',
        'searchType': 'CHUNKS',
        'maxResults': 2,
        'maxTokens': 256,
        'autoRecall': True,
        'autoIndex': True,
        'autoCognify': True,
        'deleteMode': 'soft',
        'requestTimeoutMs': 60000,
        'ingestionTimeoutMs': 300000,
        'username': 'scott@openclaw.ai',
        'password': 'openclaw2026'
    }
}

with open('$CONFIG', 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print('  openclaw.json 已更新')
"

# Step 5: Validate
echo ""
echo "=== Step 5: Validate Config ==="
openclaw config validate 2>&1 | tail -1

# Step 6: Restart
echo ""
echo "=== Step 6: Restart Gateway ==="
openclaw gateway restart 2>&1 | grep -E 'plugin|restart|error' | tail -5

# Step 7: Smoke test
echo ""
echo "=== Step 7: Smoke Test ==="

echo "  MemOS write..."
W=$(curl -sf --max-time 30 -X POST "http://$NAS_IP:8765/product/add" \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"openclaw-$MACHINE_ID\",\"async_mode\":\"sync\",\"messages\":[{\"role\":\"user\",\"content\":\"Onboarding test from $MACHINE_ID\"},{\"role\":\"assistant\",\"content\":\"OK\"}]}" 2>&1 || echo "FAIL")
echo "$W" | grep -q "memory_id" && echo "  ✅ MemOS write OK" || echo "  ❌ MemOS write failed"

sleep 8
echo "  MemOS search..."
S=$(curl -sf --max-time 30 -X POST "http://$NAS_IP:8765/product/search" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"onboarding $MACHINE_ID\",\"user_id\":\"openclaw-$MACHINE_ID\",\"top_k\":5}" 2>&1 || echo "FAIL")
echo "$S" | grep -q "memories.*memory\|text_mem.*id" && echo "  ✅ MemOS search OK" || echo "  ⚠️ MemOS search empty (may need more time)"

echo ""
echo "============================================"
echo "  Onboarding Complete!"
echo "  NAS: $NAS_IP"
echo "  Machine: $MACHINE_ID"
echo "  Dataset: openclaw-$MACHINE_ID-v1"
echo "  MemOS user: openclaw-$MACHINE_ID"
echo "============================================"
