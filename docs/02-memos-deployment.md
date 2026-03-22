# MemOS 部署（L3 — 跨機器結構化記憶）

## 1. 啟動 Neo4j + Qdrant

```bash
DOCKER=/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker

# Neo4j
$DOCKER run -d --name oc-neo4j --restart unless-stopped \
  -e NEO4J_ACCEPT_LICENSE_AGREEMENT=yes \
  -e 'NEO4J_AUTH=neo4j/YOUR_PASSWORD' \
  -p 7474:7474 -p 7687:7687 \
  -v /share/CACHEDEV1_DATA/Container/openclaw-memory/neo4j-data:/data \
  neo4j:5.26.4

# Qdrant
$DOCKER run -d --name oc-qdrant --restart unless-stopped \
  -p 6333:6333 -p 6334:6334 \
  -v /share/CACHEDEV1_DATA/Container/openclaw-memory/qdrant-data:/qdrant/storage \
  qdrant/qdrant:v1.15.3

# 等待就緒
sleep 20
curl -sf http://127.0.0.1:7474 && echo "Neo4j OK"
curl -sf http://127.0.0.1:6333 && echo "Qdrant OK"
```

## 2. 構建 MemOS Image

```bash
cd /share/CACHEDEV1_DATA/Container/openclaw-memory
git clone --depth 1 https://github.com/MemTensor/MemOS.git

$DOCKER build -t local/memos-api:latest -f MemOS/docker/Dockerfile MemOS/
```

## 3. 修復 Neo4j Map 類型錯誤

> ⚠️ **關鍵修復**：MemOS 2.0.10 的 `neo4j_community.py` 在 `n += node.metadata` 時，metadata 中的嵌套 dict/list 會觸發 Neo4j `Map{}` 類型錯誤，導致寫入成功但搜索永遠為空。

```bash
# 從容器提取原始文件
$DOCKER cp oc-memos-api:/app/src/memos/graph_dbs/neo4j_community.py \
  /share/CACHEDEV1_DATA/Container/openclaw-memory/neo4j_community_patched.py
```

在本地機器（有 Python3）執行 patch：

```bash
python3 patches/patch_neo4j_community.py neo4j_community_patched.py
```

上傳 patched 文件回 NAS，然後用 volume mount 啟動（見步驟 4）。

### 修復原理

```
問題：Cypher `n += node.metadata` 要求所有 value 是原始類型
      但 metadata 裡有 dict（如 sources 是 JSON string array）
      和 nested objects，Neo4j 5.26 拒絕 Map{} 類型

修法：_flatten_metadata_for_neo4j() 函數
      - dict → json.dumps(string)
      - list → [str(item) for item in list]
      - None → ""
      - 其他 → str(v)
```

## 4. 啟動 MemOS API

```bash
$DOCKER run -d --name oc-memos-api --restart unless-stopped \
  --link oc-neo4j --link oc-qdrant -p 8765:8000 \
  -e PYTHONPATH=/app/src -e HF_ENDPOINT=https://hf-mirror.com -e TZ=Asia/Shanghai \
  -e MOS_CUBE_PATH=/app/data \
  -e MOS_ENABLE_DEFAULT_CUBE_CONFIG=true \
  -e MOS_ENABLE_REORGANIZE=false \
  -e MOS_TEXT_MEM_TYPE=general_text \
  -e ASYNC_MODE=sync -e MOS_TOP_K=20 \
  -e MOS_CHAT_MODEL_PROVIDER=openai \
  -e MOS_CHAT_MODEL=Qwen/Qwen2.5-72B-Instruct \
  -e MOS_CHAT_TEMPERATURE=0.2 -e MOS_MAX_TOKENS=4096 -e MOS_TOP_P=0.9 \
  -e OPENAI_API_KEY=YOUR_SILICONFLOW_KEY \
  -e OPENAI_API_BASE=https://api.siliconflow.cn/v1 \
  -e MEMRADER_MODEL=Qwen/Qwen2.5-72B-Instruct \
  -e MEMRADER_API_KEY=YOUR_SILICONFLOW_KEY \
  -e MEMRADER_API_BASE=https://api.siliconflow.cn/v1 -e MEMRADER_MAX_TOKENS=4096 \
  -e EMBEDDING_DIMENSION=1024 \
  -e MOS_EMBEDDER_BACKEND=universal_api -e MOS_EMBEDDER_PROVIDER=openai \
  -e MOS_EMBEDDER_MODEL=BAAI/bge-m3 \
  -e MOS_EMBEDDER_API_BASE=https://api.siliconflow.cn/v1 \
  -e MOS_EMBEDDER_API_KEY=YOUR_SILICONFLOW_KEY \
  -e MOS_RERANKER_BACKEND=cosine_local \
  -e ENABLE_INTERNET=false -e ENABLE_PREFERENCE_MEMORY=true \
  -e MEM_READER_BACKEND=simple_struct \
  -e MEM_READER_CHAT_CHUNK_TYPE=default \
  -e MEM_READER_CHAT_CHUNK_TOKEN_SIZE=1600 \
  -e MEM_READER_CHAT_CHUNK_SESS_SIZE=10 \
  -e MEM_READER_CHAT_CHUNK_OVERLAP=2 \
  -e MOS_ENABLE_SCHEDULER=false -e API_SCHEDULER_ON=false \
  -e NEO4J_BACKEND=neo4j-community \
  -e NEO4J_URI=bolt://oc-neo4j:7687 \
  -e NEO4J_USER=neo4j -e NEO4J_PASSWORD=YOUR_PASSWORD \
  -e NEO4J_DB_NAME=neo4j -e MOS_NEO4J_SHARED_DB=false \
  -e QDRANT_HOST=oc-qdrant -e QDRANT_PORT=6333 \
  -e AUTH_ENABLED=false \
  -v /share/CACHEDEV1_DATA/Container/openclaw-memory/memos-data:/app/data \
  -v /share/CACHEDEV1_DATA/Container/openclaw-memory/neo4j_community_patched.py:/app/src/memos/graph_dbs/neo4j_community.py:ro \
  local/memos-api:latest
```

## 5. 驗證

### API 格式（關鍵！）

> ⚠️ `/product/add` 必須用 **chat message array**，不能用 `{"text": "..."}`（靜默失敗！）

```bash
# 寫入
curl -X POST http://YOUR_NAS:8765/product/add \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "test",
    "async_mode": "sync",
    "messages": [
      {"role": "user", "content": "Test memory"},
      {"role": "assistant", "content": "OK"}
    ]
  }'

# 搜索
curl -X POST http://YOUR_NAS:8765/product/search \
  -H "Content-Type: application/json" \
  -d '{"query": "test", "user_id": "test", "top_k": 5}'
```

### 成功標準

- Write 返回 `memory_id` + `memory_type`
- Search 返回 `text_mem` 或 `pref_mem` 中有結果
- `vector_sync: "success"` 在結果 metadata 中
