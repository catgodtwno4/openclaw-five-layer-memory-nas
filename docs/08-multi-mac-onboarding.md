# 多台 Mac Mini 接入指南

> 適用場景：你有多台 Mac Mini 都跑 OpenClaw，想讓它們共享 NAS 上的 MemOS 和 Cognee 服務。

## 架構

```
Mac Mini #1 (Scott#1)  ──┐
Mac Mini #2 (Scott#2)  ──┼──→ QNAP NAS ─→ MemOS :8765 + Cognee :8766
Mac Mini #3 (Scott#3)  ──┤                    │
Mac Mini #4 (Scott#4)  ──┘               Neo4j + Qdrant + LanceDB
```

每台 Mac 本地仍有 L0-L3（Markdown / lossless-claw / LanceDB Pro / QMD），NAS 提供 L2+（MemOS）和 L4（Cognee）的共享後端。

## 前提條件

每台 Mac 需要：
- OpenClaw 2026.3.x 已安裝運行
- 與 NAS 在同一局域網（能 `ping NAS_IP`）
- SiliconFlow API Key（用於本地 LanceDB Pro embedding）

## Step 1：驗證網路連通

```bash
# 替換為你的 NAS IP
NAS_IP=10.10.10.66

curl -sf http://$NAS_IP:8765/docs > /dev/null && echo "✅ MemOS 可達" || echo "❌ MemOS 不可達"
curl -sf http://$NAS_IP:8766/docs > /dev/null && echo "✅ Cognee 可達" || echo "❌ Cognee 不可達"
curl -sf http://$NAS_IP:7474 > /dev/null && echo "✅ Neo4j 可達" || echo "❌ Neo4j 不可達"
curl -sf http://$NAS_IP:6333 > /dev/null && echo "✅ Qdrant 可達" || echo "❌ Qdrant 不可達"
```

> ⚠️ 如果不通，檢查 NAS 防火牆是否允許這些端口的局域網訪問。

## Step 2：安裝 Cognee 插件

```bash
openclaw plugins install @cognee/cognee-openclaw
```

> ⚠️ 這會搶佔 memory slot！下一步會修正。

## Step 3：建立 Cognee Sidecar 克隆

```python
# 下載克隆腳本
curl -sL https://raw.githubusercontent.com/catgodtwno4/openclaw-five-layer-memory-nas/main/scripts/make_cognee_sidecar_clone.py -o /tmp/make_sidecar.py

# 執行
python3 /tmp/make_sidecar.py --force
```

或手動克隆（見 [Mac 配置文檔](04-mac-openclaw-config.md)）。

## Step 4：Cognee 帳號

每台 Mac 可以共用同一個 Cognee 帳號，但**建議用不同的 dataset name** 避免數據混淆：

| 機器 | dataset name |
|------|-------------|
| Scott#1 | `openclaw-scott1-v1` |
| Scott#2 | `openclaw-scott2-v1` |
| Scott#3 | `openclaw-scott3-v1` |
| Scott#4 | `openclaw-scott4-v1` |

如果 NAS 上的 Cognee 容器被重建過，需要重新 register：

```bash
NAS_IP=10.10.10.66

# 檢查帳號是否存在（會返回 token 或失敗）
curl -s -X POST http://$NAS_IP:8766/api/v1/auth/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d 'username=scott@openclaw.ai&password=openclaw2026'

# 如果失敗，重新註冊
curl -s -X POST http://$NAS_IP:8766/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"scott@openclaw.ai","password":"openclaw2026"}'
```

## Step 5：修改 openclaw.json

在每台 Mac 的 `~/.openclaw/openclaw.json` 中修改 plugins 部分：

```jsonc
{
  "plugins": {
    "slots": {
      "memory": "memory-lancedb-pro"  // ← LanceDB Pro 佔 slot
    },
    "allow": [
      "lossless-claw",
      "memory-lancedb-pro",
      "cognee-sidecar-openclaw",     // ← 加入允許列表
      "telegram"
      // ... 其他已有的插件
    ],
    "entries": {
      // ... 保留你已有的插件配置 ...

      // 禁用原版 Cognee（佔 slot 會衝突）
      "cognee-openclaw": {
        "enabled": false
      },

      // 啟用 sidecar 版本
      "cognee-sidecar-openclaw": {
        "enabled": true,
        "config": {
          "baseUrl": "http://NAS_IP:8766",        // ← 替換為你的 NAS IP
          "datasetName": "openclaw-YOUR_MACHINE-v1", // ← 每台機器不同！
          "searchType": "CHUNKS",
          "maxResults": 2,
          "maxTokens": 256,
          "autoRecall": true,
          "autoIndex": true,
          "autoCognify": true,
          "deleteMode": "soft",
          "requestTimeoutMs": 60000,
          "ingestionTimeoutMs": 300000,
          "username": "scott@openclaw.ai",
          "password": "openclaw2026"
        }
      }
    }
  }
}
```

## Step 6：驗證配置並重啟

```bash
# 驗證
openclaw config validate
# 應返回：Config valid

# 重啟
openclaw gateway restart
```

確認輸出包含：
```
[plugins] memory-lancedb-pro@x.x.x: plugin registered
[plugins] cognee-sidecar-openclaw: loaded
```

## Step 7：冒煙測試

### 測試 MemOS（從 Mac 端）

```bash
NAS_IP=10.10.10.66
MACHINE_ID="scott4"  # 替換為你的機器名

# 寫入
curl -s -X POST http://$NAS_IP:8765/product/add \
  -H "Content-Type: application/json" \
  -d "{
    \"user_id\": \"openclaw-$MACHINE_ID\",
    \"async_mode\": \"sync\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"This is a test from $MACHINE_ID\"},
      {\"role\": \"assistant\", \"content\": \"Acknowledged from $MACHINE_ID\"}
    ]
  }"

sleep 10

# 搜索
curl -s -X POST http://$NAS_IP:8765/product/search \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"test from $MACHINE_ID\", \"user_id\": \"openclaw-$MACHINE_ID\", \"top_k\": 5}"
```

### 測試 Cognee（從 Mac 端）

```bash
NAS_IP=10.10.10.66
DS_NAME="openclaw-scott4-v1"

# Login
TOKEN=$(curl -s -X POST http://$NAS_IP:8766/api/v1/auth/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d 'username=scott@openclaw.ai&password=openclaw2026' | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

# Add
echo "Smoke test from $(hostname)" > /tmp/smoke.txt
curl -s -X POST http://$NAS_IP:8766/api/v1/add \
  -H "Authorization: Bearer $TOKEN" \
  -F "data=@/tmp/smoke.txt" \
  -F "datasetName=$DS_NAME"

# Cognify
curl -s -X POST http://$NAS_IP:8766/api/v1/cognify \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"datasets\":[\"$DS_NAME\"]}"

# Search
curl -s -X POST http://$NAS_IP:8766/api/v1/search \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query":"smoke test","searchType":"CHUNKS"}'
```

## 注意事項

### 1. MemOS user_id 命名規則

每台機器用不同的 `user_id`，格式建議：`openclaw-{machine_name}`

```
openclaw-scott1
openclaw-scott2
openclaw-scott3
openclaw-scott4
```

MemOS 按 `user_id` 隔離記憶。如果多台機器用同一個 `user_id`，記憶會混在一起（有時這是你想要的，比如跨機器共享同一個用戶的記憶）。

### 2. Cognee dataset 命名

每台機器用不同的 `datasetName`，格式：`openclaw-{machine}-v{N}`

```
openclaw-scott1-v1
openclaw-scott2-v1
```

如果一個 dataset 進入 `DATASET_PROCESSING_ERRORED` 狀態，直接建新 dataset（改 v1 → v2），不要試圖修復舊的。

### 3. LanceDB Pro 不走 NAS

LanceDB Pro（L2）始終是**本地**的：
- 數據在 `~/.openclaw-data/memory-lancedb/`
- 佔據 `plugins.slots.memory`
- 提供 autoCapture / autoRecall

它與 NAS 上的 MemOS/Cognee 是**互補關係**，不是替代。

### 4. Cognee sidecar 注入量控制

如果 `<cognee_memories>` 注入太大導致上下文溢出：

```json
{
  "maxResults": 2,     // 減少返回條數
  "maxTokens": 256     // 減少每條 token 上限
}
```

已在 sidecar patch 中加了：
- 每條 chunk 截斷 800 字符
- 按源文件去重
- 總注入量上限 3000 字符

### 5. 網路中斷處理

如果 NAS 離線或網路中斷：
- L0-L3（本地層）不受影響，OpenClaw 正常運行
- L2+（MemOS）和 L4（Cognee）的 recall 會 timeout 並被跳過
- 不會導致 OpenClaw 崩潰或 Gateway 掛掉
- NAS 恢復後自動恢復正常

### 6. 多台 Mac 同時寫入

MemOS 和 Cognee 都支持並發寫入：
- MemOS：不同 `user_id` 完全隔離
- Cognee：不同 `datasetName` 完全隔離
- Neo4j/Qdrant 本身支持並發

但建議避免同一台 NAS 上跑超過 4-5 台 Mac 的並發 cognify（LLM 調用密集，可能碰到 SiliconFlow rate limit）。

### 7. 備份

定期備份 NAS 上的數據目錄：

```bash
# 在 NAS 上
DEPLOY=/share/CACHEDEV1_DATA/Container/openclaw-memory
tar czf /share/homes/openclaw/memory-backup-$(date +%Y%m%d).tar.gz \
  $DEPLOY/memos-data \
  $DEPLOY/neo4j-data \
  $DEPLOY/qdrant-data \
  $DEPLOY/cognee-data
```

### 8. SiliconFlow API Key 共用

所有服務（MemOS + Cognee + 各 Mac 的 LanceDB Pro）都可以用同一個 SiliconFlow API Key。但注意：
- **免費額度有限**：Cognee 的 cognify 會密集調用 LLM
- **建議監控用量**：https://cloud.siliconflow.cn 查看 API 用量
- 如果接近限額，可以減少 `autoCognify` 頻率

## 完整接入清單（Checklist）

```
□ 網路連通（curl 4 個端口）
□ cognee-openclaw 插件已安裝
□ sidecar 克隆已建立
□ sidecar client.js / plugin.js 已 patch
□ openclaw.json 已修改
  □ slots.memory = "memory-lancedb-pro"
  □ cognee-openclaw.enabled = false
  □ cognee-sidecar-openclaw.enabled = true + config
□ openclaw config validate 通過
□ openclaw gateway restart 成功
□ MemOS write + search 冒煙測試通過
□ Cognee add + cognify + search 冒煙測試通過
```
