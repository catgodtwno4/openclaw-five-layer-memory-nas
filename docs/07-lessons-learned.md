# 踩坑紀錄

## 時間線

從零到全通花了約 8 小時（2026-03-22 08:00 → 15:50 CST）。

## 最耗時的坑

### 🏆 第一名：NAS Docker Build 慢（3+ 小時）

代理網速 ~50KB/s，Cognee 的 apt-get 裝了 184 個包（gcc, clang, cmake, llvm, git...），每個包都要走代理。

**教訓**：
- 先在本地 Mac 用 colima QEMU build linux/amd64 image，再 `docker save | gzip | scp` 到 NAS
- 但 `docker load` 在 QNAP 上也可能失敗（exit 255），所以最終還是 NAS 原生 build
- **結論**：沒有捷徑，NAS 原生 build + 代理 + 鏡像源 + 耐心

### 🥈 第二名：MemOS 搜索空（2+ 小時排查）

Write 返回 200 + memory_id，看起來完全成功，但 Search 永遠空。

排查路徑：
1. ❌ API 格式問題？→ 不是（用了正確的 messages array）
2. ❌ SiliconFlow token？→ 不是（容器內手動 embedding 正常）
3. ❌ Neo4j 版本？→ 不是（Scott#1 也用 5.26.4）
4. ❌ Qdrant indexed_vectors_count = 0？→ 不是（正常行為，< threshold）
5. ✅ **Neo4j Map{} 類型錯誤** → 找到了！metadata 有嵌套 dict

**教訓**：
- `docker logs` 裡的 ERROR 才是真相，不要只看 API 返回
- Neo4j 5.26 對 property 類型檢查很嚴格
- Volume mount patch 才能持久化

### 🥉 第三名：QNAP sudoers 路徑（30 分鐘）

改了 3 次 `/etc/sudoers` 都無效，最後發現 QNAP 讀的是 `/usr/etc/sudoers`。

**教訓**：QNAP 的 Linux 和標準 Linux 不一樣，很多路徑都非標準。

## 其他教訓

### Docker daemon config

鏡像源和代理要**同時配**：
- 只配鏡像源：下載極慢（900+ 秒卡住）
- 只配代理：DNS 可能被污染（auth.docker.io → Facebook IP）
- 兩個都配：穩定且快

### Cognee auth

`ENABLE_BACKEND_ACCESS_CONTROL=false` 是假的——設了但不生效。每次容器重建都要重新 register。解法：把 `.cognee_system` 掛載到 volume。

### SSH 超時

NAS 的 SSH 在長操作時會超時（exit 255）。所有 build/load 操作都要 background：

```bash
sudo sh -c 'command > /tmp/log 2>&1; echo $? > /tmp/rc' &
```

然後另一個 SSH session 監控 `/tmp/log` 和 `/tmp/rc`。

### 不要說「10 分鐘」

NAS build 預估永遠不準。說了 N 次「10 分鐘」，實際花了 3+ 小時。下次直接說「看情況，完了通知你」。😂

## 配置備忘

| 項目 | 值 |
|------|-----|
| NAS IP | 10.10.10.66 |
| Neo4j auth | neo4j / openclaw2026 |
| Cognee auth | scott@openclaw.ai / openclaw2026 |
| SiliconFlow | sk-cpq... (bge-m3 + Qwen2.5-72B) |
| 代理 | http://10.10.20.2:7890 |
| 部署目錄 | /share/CACHEDEV1_DATA/Container/openclaw-memory/ |
