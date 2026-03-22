# 5A+ Final Test Results

> 2026-03-22 21:55-21:58 CST — Scott#4 (Mac Mini)

## Configuration

| Layer | Component | LLM | Embedding |
|-------|-----------|-----|-----------|
| L0 | Markdown (5 files) | — | — |
| L1 | lossless-claw | MiniMax M2.7 HS | — |
| L2 | LanceDB Pro | — | BAAI/bge-m3 (SiliconFlow) |
| L3 | QMD | — (BM25) | — |
| L2+ | MemOS (NAS) | MiniMax M2.7 HS | BAAI/bge-m3 (SiliconFlow) |
| L4 | Cognee (NAS) | MiniMax M2.7 HS | BAAI/bge-m3 (SiliconFlow) |

All MiniMax models on Ultra Annual Plan (30,000 calls/5hr).

## Test: 10 Rounds × 9 Tests = 96 Total

### Result: 96/96 PASS (100%) — 🏆 5A+ CERTIFIED

### Performance Statistics

| Layer | Avg | Min | Max | P50 | P95 | Std |
|-------|-----|-----|-----|-----|-----|-----|
| L0 files | 17ms | 16ms | 18ms | 17ms | 18ms | 0ms |
| L1 config | 2,026ms | 1,979ms | 2,088ms | 2,013ms | 2,088ms | 34ms |
| L2 vectors | 2,008ms | 1,963ms | 2,029ms | 2,016ms | 2,029ms | 18ms |
| L3 QMD | 342ms | 332ms | 357ms | 340ms | 357ms | 8ms |
| **L2+ write** | **10,751ms** | 6,764ms | 13,062ms | 11,799ms | 13,062ms | 1,860ms |
| **L2+ search** | **301ms** | 185ms | 706ms | 308ms | 706ms | 146ms |
| **L4 add** | **2,174ms** | 1,633ms | 5,233ms | 1,810ms | 5,233ms | 1,030ms |
| **L4 search** | **354ms** | 242ms | 1,090ms | 267ms | 1,090ms | 246ms |
| X gateway | 3,215ms | 2,616ms | 3,820ms | 3,348ms | 3,820ms | 385ms |

### Latency Breakdown

| Operation | Bottleneck | Why |
|-----------|-----------|-----|
| L2+ write ~10.7s | MiniMax M2.7 HS LLM call | Memory extraction pipeline: LLM call (4-9s) + embedding (160ms) + Neo4j/Qdrant write (200ms) |
| L2+ search ~301ms | Neo4j + Qdrant query | Fast — no LLM involved |
| L4 add ~2.2s | File upload + pipeline | Reasonable |
| L4 search ~354ms | LanceDB vector search | Fast |

### Sanitize Improvement (Before/After)

Applied Scott#1's `<think>` tag sanitization to Cognee sidecar:
- Strip `<think>...</think>` blocks on recall
- Strip `reasoning_*` fields
- Total cap 3000 chars maintained

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| L2+ write max | 30,167ms | 13,062ms | **↓57%** |
| L2+ write avg | 12,419ms | 10,751ms | **↓13%** |
| L2+ search avg | 242ms | 301ms | +24% (within variance) |
| L4 search avg | 328ms | 354ms | +8% (within variance) |
| Pass rate | 100% | 100% | = |
| `<think>` contamination | 0 found | 0 found | = |

### NAS Container Health

| Container | Status |
|-----------|--------|
| oc-memos-api | ✅ Running |
| oc-cognee-api | ✅ Running |
| oc-neo4j | ✅ Running |
| oc-qdrant | ✅ Running |

### Cross-Layer Integrity

- Memory slot: `memory-lancedb-pro` (no conflict) ✅
- Cognee sidecar: no `kind` (no slot collision) ✅
- Gateway: 0 critical issues ✅
- Embedding consistency: All layers use BAAI/bge-m3 ✅

## Patches Applied (Volume Mount)

| File | Purpose |
|------|---------|
| `LiteLLMEmbeddingEngine.py` | Suppress `dimensions` param for SiliconFlow |
| `config.py` | 3072→1024 embedding dims |
| `adapter.py` | System→user role merge + `<think>` strip + max_tokens |
| `get_llm_client.py` | Add `endpoint` to CUSTOM provider (Cognee source bug fix) |

All patches mounted as `:ro` volumes — survive container restart.

## Key Findings

1. **MiniMax M2 series all have `<think>` reasoning** — cannot be disabled via API
2. **MiniMax doesn't accept `system` role** through litellm→instructor path — fixed by merging into user message
3. **Cognee 0.5.5 has a source bug** — CUSTOM provider missing `endpoint` parameter in `get_llm_client.py`
4. **MemOS automatically strips `<think>`** — no additional patch needed
5. **LanceDB Pro has built-in Ebbinghaus decay** — 60-day half-life + recall strengthening
