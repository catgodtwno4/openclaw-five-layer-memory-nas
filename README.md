# OpenClaw 五層記憶棧 — QNAP NAS 部署指南

> **實戰驗證**：2026-03-22 在 QNAP NAS (QTS 5.2.8, x86_64) 上從零部署完成，5A+ 測試全數通過。

## 架構總覽

```
┌─────────────────────────────────────────────────────────┐
│                    Mac Mini (OpenClaw)                    │
│                                                          │
│  L0 Markdown ─── L1 lossless-claw ─── L2 LanceDB Pro   │
│       │                                     │            │
│       │              L3 QMD (BM25)          │            │
│       │                                     │            │
│       └──── L4 Cognee Sidecar ──────────────┘            │
│                    │           │                          │
└────────────────────┼───────────┼──────────────────────────┘
                     │           │
            ┌────────┴───────────┴────────┐
            │      QNAP NAS (Docker)       │
            │                              │
            │  ┌─────────┐ ┌────────────┐  │
            │  │  Neo4j   │ │   Qdrant   │  │
            │  │  :7474   │ │   :6333    │  │
            │  └────┬─────┘ └─────┬──────┘  │
            │       │             │          │
            │  ┌────┴─────────────┴──────┐   │
            │  │      MemOS API          │   │
            │  │      :8765 (L2+)        │   │
            │  └─────────────────────────┘   │
            │                                │
            │  ┌─────────────────────────┐   │
            │  │     Cognee API          │   │
            │  │     :8766 (L4)          │   │
            │  │  (自帶 LanceDB 向量庫)   │   │
            │  └─────────────────────────┘   │
            └────────────────────────────────┘
```

## 各層說明

| 層 | 組件 | 位置 | 觸發時機 | 功能 | LLM 分配 |
|----|------|------|---------|------|---------|
| L0 | Markdown | Mac 本地 | 永遠在 | 持久記憶檔（SOUL.md / MEMORY.md / lessons.md） | — |
| L1 | lossless-claw | Mac 本地 | 上下文滿 | 上下文無損壓縮（DAG 摘要） | MiniMax M2.7 HS |
| L2 | LanceDB Pro | Mac 本地 | 會話結束 | 語義向量搜索 + Rerank | BAAI/bge-m3 (SiliconFlow) |
| L2+ | MemOS | **NAS** | 跨會話 | 跨機器結構化記憶（fact/preference/skill 自動分類） | MiniMax M2.7 HS + BAAI/bge-m3 |
| L3 | QMD | Mac 本地 | 查詢時 | BM25 精確關鍵字搜索 | — |
| L4 | Cognee | **NAS** | 啟動時 | 知識圖譜 + chunk 級語義搜索 | MiniMax M2.7 HS + BAAI/bge-m3 |

## 快速開始

### 前提條件

- QNAP NAS with Container Station（Docker 27.x）
- 至少 4GB RAM 可用
- SiliconFlow API Key（LLM + Embedding）
- Mac 上已安裝 OpenClaw 2026.3.x

### 接入已有 NAS（其他 Mac Mini）

```bash
# 一鍵接入（替換 IP 和機器名）
bash scripts/onboard-mac.sh 10.10.10.66 scott4
```

### 從零部署 NAS

```bash
# 1. SSH 到 NAS
ssh openclaw@YOUR_NAS_IP

# 2. 建立部署目錄
mkdir -p /share/CACHEDEV1_DATA/Container/openclaw-memory
cd /share/CACHEDEV1_DATA/Container/openclaw-memory

# 3. 下載配置
git clone https://github.com/catgodtwno4/openclaw-five-layer-memory-nas.git .

# 4. 設定環境變量
cp .env.example .env
# 編輯 .env 填入你的 SiliconFlow API Key

# 5. 啟動所有服務
bash scripts/deploy-all.sh
```

## 詳細部署文檔

- [QNAP NAS 環境準備](docs/01-qnap-setup.md)
- [MemOS 部署（L2+）](docs/02-memos-deployment.md)
- [Cognee 部署（L4）](docs/03-cognee-deployment.md)
- [Mac 端 OpenClaw 配置](docs/04-mac-openclaw-config.md)
- [測試與驗證](docs/05-testing.md)
- [已知問題與修復](docs/06-known-issues.md)
- [踩坑紀錄](docs/07-lessons-learned.md)
- [**多台 Mac Mini 接入指南**](docs/08-multi-mac-onboarding.md) — 含注意事項、命名規則、Checklist

## 環境資訊

| 項目 | 版本 |
|------|------|
| QNAP QTS | 5.2.8 |
| Docker | 27.1.2-qnap8 |
| Neo4j | 5.26.4 |
| Qdrant | v1.15.3 |
| MemOS | 2.0.10 |
| Cognee | 0.5.5-local |
| OpenClaw | 2026.3.13 |
| L1 LLM | MiniMax M2.7 HS |
| L2 Embedding | BAAI/bge-m3 (SiliconFlow, 1024 dims) |
| L2+ LLM | MiniMax M2.7 HS |
| L2+ Embedding | BAAI/bge-m3 (SiliconFlow) |
| L4 LLM | MiniMax M2.7 HS |
| L4 Embedding | BAAI/bge-m3 (SiliconFlow) |


## Dashboard

執行 `scripts/memory-dashboard.sh` 可查看五層記憶棧的即時狀態摘要：

```bash
bash scripts/memory-dashboard.sh
```

Dashboard 顯示內容：

| 面板 | 說明 |
|------|------|
| 🗄️ L2 LanceDB Pro | 向量庫條目數、索引狀態、最近寫入時間 |
| 🧠 L2+ MemOS | NAS API 健康狀態、記憶條目總數、分類統計（fact/preference/skill） |
| 🕸️ L4 Cognee | 知識圖譜節點數、關係數、最近 cognify 時間 |
| 🔍 L3 QMD | BM25 索引大小、最後更新時間 |
| 🐳 Docker Services | NAS 上各容器（Neo4j / Qdrant / MemOS / Cognee）健康狀態 |
| 📊 Overall Health | 五層整體健康分數（5A+ 評級） |

## Test Results

最新測試結果：**96/96 = 100%** ✅（含 MiniMax M2.7 HS 遷移後驗證）

詳細測試報告：[docs/5a-test-results-final.md](docs/5a-test-results-final.md)

```
L0  Markdown:      9/9   ✅
L1  lossless-claw: 2/2   ✅
L2  LanceDB Pro:   3/3   ✅
L2+ MemOS:        16/16  ✅
L3  QMD:           2/2   ✅
L4  Cognee:       28/28  ✅
Cross-layer:      36/36  ✅

Total: 96/96 = 100% ✅
```

測試腳本位於 `scripts/` 目錄：
- `scripts/final_5a_test.sh` — 完整 5A+ 測試套件
- `scripts/stability_test.sh` — 穩定性壓測腳本

## MiniMax Migration

LLM 已從 Qwen2.5-72B-Instruct 遷移至 **MiniMax M2.7 HS**，國內直連無需代理，延遲更低。

遷移文檔：[docs/minimax-migration.md](docs/minimax-migration.md)

遷移重點：
- L1 lossless-claw → MiniMax M2.7 HS（替換 Qwen2.5-72B）
- L2+ MemOS → MiniMax M2.7 HS + BAAI/bge-m3（保留 SiliconFlow embedding）
- L4 Cognee → MiniMax M2.7 HS + BAAI/bge-m3（保留 SiliconFlow embedding）
- 遷移後跑 96/96 測試全數通過 ✅

## 相關倉庫

| 倉庫 | 說明 |
|------|------|
| [openclaw-lcm-setup](https://github.com/catgodtwno4/openclaw-lcm-setup) | LCM 安裝配置指南 |
| [openclaw-dashboard](https://github.com/catgodtwno4/openclaw-dashboard) | OpenClaw 儀表板 |
| [openclaw-browser](https://github.com/catgodtwno4/openclaw-browser) | 瀏覽器自動化 Skill |
| [openclaw-im-control](https://github.com/catgodtwno4/openclaw-im-control) | 媒體傳送 Skill |
| [lossless-claw](https://github.com/catgodtwno4/lossless-claw) | LCM 插件 Fork（含修復） |

## 許可證

MIT
