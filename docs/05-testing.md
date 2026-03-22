# 測試與驗證

## 快速冒煙測試

```bash
bash scripts/smoke-test.sh YOUR_NAS_IP
```

## 手動驗證清單

### NAS 端

| 測試項 | 命令 | 期望結果 |
|--------|------|---------|
| Neo4j | `curl http://NAS:7474` | HTTP 200 |
| Qdrant | `curl http://NAS:6333` | `{"status":"ok"}` |
| MemOS | `curl http://NAS:8765/docs` | HTML page |
| Cognee | `curl http://NAS:8766/docs` | HTML page |
| 4 容器 | `docker ps` | 4 containers running |

### MemOS Write + Search

```bash
# Write
curl -X POST http://NAS:8765/product/add \
  -H "Content-Type: application/json" \
  -d '{"user_id":"test","async_mode":"sync","messages":[{"role":"user","content":"Test"},{"role":"assistant","content":"OK"}]}'
# → 應返回 memory_id

sleep 10

# Search
curl -X POST http://NAS:8765/product/search \
  -H "Content-Type: application/json" \
  -d '{"query":"test","user_id":"test","top_k":5}'
# → text_mem 應有結果
```

### Cognee Add + Cognify + Search

```bash
# Login
TOKEN=$(curl -s -X POST http://NAS:8766/api/v1/auth/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d 'username=scott@openclaw.ai&password=openclaw2026' | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

# Add
echo "Test data" > /tmp/t.txt
curl -X POST http://NAS:8766/api/v1/add \
  -H "Authorization: Bearer $TOKEN" \
  -F "data=@/tmp/t.txt" -F "datasetName=test"
# → PipelineRunCompleted

# Cognify
curl -X POST http://NAS:8766/api/v1/cognify \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"datasets":["test"]}'
# → PipelineRunCompleted

# Search
curl -X POST http://NAS:8766/api/v1/search \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query":"test","searchType":"CHUNKS"}'
# → JSON array with text results
```

### Mac 端

```bash
openclaw config validate  # → "Config valid"
openclaw gateway restart  # → plugins loaded without errors
```

## 5A+ 壓力測試

見 `scripts/five-layer-stress-test.sh`（5 輪 MemOS + 5 輪 Cognee，自動判定）
