# Cognee 部署（L4 — 知識圖譜）

## 1. 構建 Cognee Image（NAS 原生 x86_64）

### Dockerfile 修改

Cognee 官方 Dockerfile 需要修改兩處：

```dockerfile
# 1. 加大 UV 超時（代理環境下大包下載慢）
ENV UV_HTTP_TIMEOUT=600

# 2. 移除 --extra postgres（避免 QEMU 環境下 psycopg2 SIGSEGV）
# 原始：uv sync --extra debug --extra api --extra neo4j --extra postgres ...
# 修改：uv sync --extra debug --extra api --extra neo4j --extra llama-index ...
```

### Pre-pull Base Images

```bash
DOCKER=/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker

# Python base（走鏡像源）
$DOCKER pull docker.1ms.run/library/python:3.12-slim-bookworm
$DOCKER tag docker.1ms.run/library/python:3.12-slim-bookworm python:3.12-slim-bookworm

# UV（走代理直連 ghcr.io）
$DOCKER pull ghcr.io/astral-sh/uv:python3.12-bookworm-slim
```

### Build

```bash
cd /share/CACHEDEV1_DATA/Container/openclaw-memory/cognee-server

# Background build（SSH 長操作會超時）
sudo sh -c 'cd /share/CACHEDEV1_DATA/Container/openclaw-memory/cognee-server && \
  /share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker build \
  -t local/cognee-api:latest -f Dockerfile . \
  > /tmp/cognee-build.log 2>&1; echo $? > /tmp/cognee-build-rc' &

# 監控（每 2 分鐘檢查）
watch -n 120 'cat /tmp/cognee-build-rc 2>/dev/null || tail -1 /tmp/cognee-build.log'
```

> 預計 build 時間：30-90 分鐘（取決於代理網速）

## 2. Hotfix（必須！）

Cognee 0.5.5 + SiliconFlow 有兩個已知問題：

### 問題 1：dimensions 參數不兼容

SiliconFlow 的 embedding API 不接受 `dimensions` 參數，Cognee 默認會傳。

### 問題 2：默認 3072 維 → 應為 1024 維

bge-m3 是 1024 維，Cognee 默認 3072。

### 修復方式

```bash
# 從容器提取 → 本地 patch → volume mount
DOCKER=/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker
DEPLOY=/share/CACHEDEV1_DATA/Container/openclaw-memory

# 提取
$DOCKER cp oc-cognee-api:/app/cognee/infrastructure/databases/vector/embeddings/LiteLLMEmbeddingEngine.py $DEPLOY/cognee-patches/LiteLLMEmbeddingEngine.py
$DOCKER cp oc-cognee-api:/app/cognee/infrastructure/databases/vector/embeddings/config.py $DEPLOY/cognee-patches/config.py
$DOCKER cp oc-cognee-api:/app/.venv/lib/python3.12/site-packages/cognee/infrastructure/databases/vector/embeddings/LiteLLMEmbeddingEngine.py $DEPLOY/cognee-patches/venv_LiteLLMEmbeddingEngine.py
$DOCKER cp oc-cognee-api:/app/.venv/lib/python3.12/site-packages/cognee/infrastructure/databases/vector/embeddings/config.py $DEPLOY/cognee-patches/venv_config.py
```

在本地 patch（見 `patches/patch_cognee_hotfix.py`），然後上傳回 NAS。

## 3. 啟動 Cognee

```bash
$DOCKER run -d --name oc-cognee-api --restart unless-stopped \
  --link oc-neo4j -p 8766:8000 \
  -e HOST=0.0.0.0 -e ENVIRONMENT=local -e DEBUG=false -e LOG_LEVEL=INFO \
  -e ENABLE_BACKEND_ACCESS_CONTROL=false \
  -e COGNEE_SKIP_CONNECTION_TEST=true \
  -e HUGGINGFACE_TOKENIZER=BAAI/bge-m3 \
  -e LLM_API_KEY=YOUR_SILICONFLOW_KEY \
  -e LLM_MODEL=openai/Qwen/Qwen2.5-72B-Instruct -e LLM_PROVIDER=openai \
  -e LLM_ENDPOINT=https://api.siliconflow.cn/v1 \
  -e STRUCTURED_OUTPUT_FRAMEWORK=instructor -e LLM_INSTRUCTOR_MODE=json_mode \
  -e LITELLM_DROP_PARAMS=true \
  -e EMBEDDING_PROVIDER=custom -e EMBEDDING_MODEL=openai/BAAI/bge-m3 \
  -e EMBEDDING_ENDPOINT=https://api.siliconflow.cn/v1 \
  -e EMBEDDING_API_KEY=YOUR_SILICONFLOW_KEY \
  -e EMBEDDING_DIMENSIONS=1024 -e EMBEDDING_MAX_TOKENS=8191 \
  -e VECTOR_DB_PROVIDER=lancedb \
  -e GRAPH_DATABASE_URL=bolt://oc-neo4j:7687 \
  -e GRAPH_DATABASE_USERNAME=neo4j -e GRAPH_DATABASE_PASSWORD=YOUR_PASSWORD \
  -v $DEPLOY/cognee-data:/app/.cognee_system \
  -v $DEPLOY/cognee-patches/LiteLLMEmbeddingEngine.py:/app/cognee/infrastructure/databases/vector/embeddings/LiteLLMEmbeddingEngine.py:ro \
  -v $DEPLOY/cognee-patches/config.py:/app/cognee/infrastructure/databases/vector/embeddings/config.py:ro \
  -v $DEPLOY/cognee-patches/venv_LiteLLMEmbeddingEngine.py:/app/.venv/lib/python3.12/site-packages/cognee/infrastructure/databases/vector/embeddings/LiteLLMEmbeddingEngine.py:ro \
  -v $DEPLOY/cognee-patches/venv_config.py:/app/.venv/lib/python3.12/site-packages/cognee/infrastructure/databases/vector/embeddings/config.py:ro \
  local/cognee-api:latest
```

### 關鍵配置說明

| ENV | 值 | 說明 |
|-----|-----|------|
| `VECTOR_DB_PROVIDER` | `lancedb` | Cognee 0.5.5 不支持 Qdrant！只支持 LanceDB/PGVector/ChromaDB |
| `COGNEE_SKIP_CONNECTION_TEST` | `true` | 避免 connection test 假陰性 |
| `ENABLE_BACKEND_ACCESS_CONTROL` | `false` | 設了但**不生效**（0.5.5 bug），仍需 register + login |
| `HUGGINGFACE_TOKENIZER` | `BAAI/bge-m3` | 否則 tiktoken 不認識 bge-m3 |
| `LLM_INSTRUCTOR_MODE` | `json_mode` | 不能用 `markdown_json_mode`（SiliconFlow 不支持） |
| `LITELLM_DROP_PARAMS` | `true` | 防止不支持的參數傳到 SiliconFlow |

## 4. 驗證

```bash
# 1. Register（每次容器重建需要，除非 .cognee_system 掛載了）
curl -X POST http://YOUR_NAS:8766/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"scott@openclaw.ai","password":"openclaw2026"}'

# 2. Login
TOKEN=$(curl -s -X POST http://YOUR_NAS:8766/api/v1/auth/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d 'username=scott@openclaw.ai&password=openclaw2026' | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

# 3. Add（注意：field 是 datasetName 不是 dataset_name！）
echo "Test content for Cognee" > /tmp/test.txt
curl -X POST http://YOUR_NAS:8766/api/v1/add \
  -H "Authorization: Bearer $TOKEN" \
  -F "data=@/tmp/test.txt" \
  -F "datasetName=test-dataset"

# 4. Cognify（搜索前必須！）
curl -X POST http://YOUR_NAS:8766/api/v1/cognify \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"datasets":["test-dataset"]}'

# 5. Search
curl -X POST http://YOUR_NAS:8766/api/v1/search \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query":"test","searchType":"CHUNKS"}'
```

### 成功標準

- Add: `"status":"PipelineRunCompleted"`
- Cognify: `"status":"PipelineRunCompleted"`
- Search: 返回包含 `text` 字段的 JSON array
