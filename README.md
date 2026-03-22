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

| 層 | 組件 | 位置 | 功能 |
|----|------|------|------|
| L0 | Markdown | Mac 本地 | 持久記憶檔（SOUL.md / MEMORY.md / lessons.md） |
| L1 | lossless-claw | Mac 本地 | 上下文無損壓縮（DAG 摘要） |
| L2 | LanceDB Pro | Mac 本地 | 語義向量搜索 + Rerank |
| L3 | QMD | Mac 本地 | BM25 精確關鍵字搜索 |
| **L2+** | **MemOS** | **NAS** | 跨機器結構化記憶（fact/preference/skill 自動分類） |
| **L4** | **Cognee** | **NAS** | 知識圖譜 + chunk 級語義搜索 |

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
| LLM | Qwen/Qwen2.5-72B-Instruct (SiliconFlow) |
| Embedding | BAAI/bge-m3 (SiliconFlow, 1024 dims) |

## 5A+ 測試結果

```
L0 Markdown:      9/9   ✅ 100%
L1 lossless-claw: 2/2   ✅ 100%
L2 LanceDB Pro:   3/3   ✅ 100%
L3 QMD:           2/2   ✅ 100%
L2+ MemOS:       11/11  ✅ 100%  (5 輪 Write + 5 輪 Search)
L4 Cognee:       16/16  ✅ 100%  (5 輪 Add + Cognify + Search)
Cross-layer:      6/6   ✅ 100%

Total: 52/52 = 100% ✅
```

## 相關倉庫

- [openclaw-five-layer-memory-stack](https://github.com/catgodtwno1/openclaw-five-layer-memory-stack) — 層級圖、快速開始、共存矩陣
- [openclaw-cognee-rollout](https://github.com/catgodtwno1/openclaw-cognee-rollout) — Cognee sidecar 部署、hotfix 腳本
- [openclaw-memos-server](https://github.com/catgodtwno1/openclaw-memos-server) — MemOS API 格式坑、env 模板

## License

MIT
