# 已知問題與修復

## MemOS

### 1. Neo4j Map{} 類型錯誤（已修）

**症狀**：Write 返回 200 + memory_id，但 Search 永遠空。Neo4j error log 顯示 `Property values can only be of primitive types or arrays thereof. Encountered: Map{}.`

**根因**：`neo4j_community.py` 的 `n += node.metadata` 展開 metadata dict 時，嵌套的 dict/complex list 不被 Neo4j 5.26 接受。

**修法**：`_flatten_metadata_for_neo4j()` 函數，把 dict→JSON string, list→primitive array, None→""。

**持久化**：Volume mount patched file (`:ro`)，restart 不會丟。

### 2. API 格式靜默失敗

**症狀**：`/product/add` 返回 200 但搜索空。

**根因**：用了 `{"text": "..."}` 格式，但 MemOS 只接受 `{"messages": [{role, content}]}`。`text` 字段不在 API schema 裡，寫入被靜默忽略。

**修法**：用 chat message array 格式 + `"async_mode": "sync"`。

### 3. Qdrant indexed_vectors_count = 0

**不是 bug**。當 points < indexing_threshold (10000) 時，Qdrant 不建 HNSW 索引，用暴力掃描，向量搜索仍然正常。

## Cognee

### 4. ENABLE_BACKEND_ACCESS_CONTROL=false 不生效

**症狀**：設了 env 但 API 仍返回 401。

**根因**：Cognee 0.5.5 的 multi-user access control 邏輯忽略此 env。

**解法**：必須 register + login 取 Bearer token。

### 5. 字段名 camelCase

**症狀**：`dataset_name` → `ValueError: Either datasetId or datasetName must be provided`

**根因**：API 用 camelCase。

**修法**：用 `datasetName`（不是 `dataset_name`）。

### 6. Search 前必須 Cognify

**症狀**：Add 成功但 Search 返回 `NoDataError`。

**修法**：Add 後必須呼叫 `POST /api/v1/cognify {"datasets": ["name"]}`。

### 7. 向量維度不匹配

**症狀**：Validation error requiring 3072 items。

**根因**：Cognee 默認 3072 維，bge-m3 是 1024 維。

**修法**：Patch `config.py` 的 `embedding_dimensions: Optional[int] = 3072` → `1024`。

### 8. dimensions 參數不兼容

**症狀**：`UnsupportedParamsError: Setting dimensions is not supported`

**根因**：Cognee/LiteLLM 傳 `dimensions` 參數到 SiliconFlow，但不被支持。

**修法**：Patch `LiteLLMEmbeddingEngine.py` 註釋掉 dimensions 傳遞。

### 9. Cognee 不支持 Qdrant

**症狀**：`Unsupported vector database provider: qdrant`

**根因**：Cognee 0.5.5 只支持 LanceDB, PGVector, ChromaDB。

**修法**：`VECTOR_DB_PROVIDER=lancedb`（Cognee 用內部 LanceDB，Qdrant 只給 MemOS）。

### 10. Hotfix 重啟丟失

**症狀**：容器 restart 後 patch 消失。

**根因**：Docker overlay filesystem，restart 恢復到原始 image layer。

**修法**：Volume mount patched files (`:ro`)。

## 建構問題

### 11. UV 下載超時

**症狀**：`Failed to download pytz==... network timeout`

**修法**：Dockerfile 加 `ENV UV_HTTP_TIMEOUT=600`。

### 12. Docker homes 目錄權限

**症狀**：`ERROR: mkdir /share/CACHEDEV1_DATA/.qpkg/container-station/homes: permission denied`

**修法**：`sudo mkdir -p ... && sudo chmod 777 ...`

### 13. Docker ulimits 不兼容

**症狀**：`error setting rlimit type 7: invalid argument`

**修法**：從 docker.json 移除 `default-ulimits`。
