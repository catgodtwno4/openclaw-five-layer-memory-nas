# MiniMax Migration Guide

> 從 SiliconFlow Qwen-70B 遷移到 MiniMax Ultra Plan

## 概述

MiniMax Ultra 年訂包含 M2.7-highspeed 模型，~100 tok/s，30000 calls/5hr。
本指南記錄了將 MemOS 和 lossless-claw 遷移到 MiniMax 的過程和踩坑記錄。

## 已驗證可用

| 組件 | LLM | Provider | 狀態 |
|------|-----|----------|------|
| **MemOS (L2+)** | MiniMax-M2.7-highspeed | MiniMax OpenAI 兼容 | ✅ |
| **lossless-claw (L1)** | MiniMax-M2.7-highspeed | MiniMax | ✅ |

## Cognee (L4) — 尚未遷移

### 根因

Cognee 使用 `instructor` 庫做 JSON structured extraction。Instructor 會自動生成 `role: "system"` 的 messages。MiniMax API **在通過 litellm 路徑時** 拒絕 system role，報錯：

```
litellm.BadRequestError: OpenAIException - invalid params, 
chat content has invalid message role: system (2013)
```

### 嘗試過的方案（均失敗）

| 方案 | 結果 | 原因 |
|------|------|------|
| adapter.py patch（system→user） | ❌ | instructor 內部生成 system msg，adapter 攔截不到 |
| litellm success_callback | ❌ | callback 在 instructor parse 之後執行 |
| litellm.acompletion monkeypatch | ❌ | instructor 用 positional args 傳 messages |
| client.py 啟動時 monkeypatch | ❌ | 同上 |
| OPENAI_API_KEY env var | ❌ | litellm 認了 key，但 instructor 的 system msg 仍被拒 |
| LLM_PROVIDER=custom + endpoint fix | ❌ | get_llm_client.py 的 CUSTOM 分支缺 endpoint（Cognee 源碼 bug），修了 endpoint 後 litellm 仍需 provider prefix |

### Cognee 源碼 bug（已確認）

`get_llm_client.py` 的 CUSTOM provider 分支缺少 `endpoint` 參數：

```python
# BUG: 缺少 endpoint
return GenericAPIAdapter(
    llm_config.llm_api_key,
    llm_config.llm_model,
    max_completion_tokens,
    "Custom",
    # ← 這裡缺少 endpoint=llm_config.llm_endpoint
)
```

**修復**：在 "Custom" 後加 `endpoint=llm_config.llm_endpoint,`

### MiniMax M2.x 模型特性

1. **所有 M2.x 模型都帶 `<think>` reasoning 標籤**（M2.1/M2.5/M2.7/M2.7-HS）
2. `reasoning: false` / `reasoning_effort: "none"` 等 API 參數**無法關閉** `<think>`
3. System prompt 也無法禁止 `<think>`
4. MemOS 能自動 strip `<think>`，所以 MemOS 不受影響
5. Cognee 的 instructor JSON parsing 會被 `<think>` 干擾（但修了 system role 問題後可能不是問題）

### 下一步

- 等 Scott#1 的 GPT-5.4 方案解決 system role 問題
- 可能需要改 `instructor_mode` 為 `tool_call`（不用 system message）
- 或者 patch instructor 庫本身

## MemOS 遷移步驟

```bash
# docker run 時設置：
-e MOS_CHAT_MODEL=MiniMax-M2.7-highspeed
-e MOS_CHAT_MODEL_PROVIDER=openai
-e OPENAI_API_BASE=https://api.minimaxi.com/v1
-e OPENAI_API_KEY=<your-minimax-api-key>
-e MEMRADER_MODEL=MiniMax-M2.7-highspeed
-e MEMRADER_API_KEY=<your-minimax-api-key>
-e MEMRADER_API_BASE=https://api.minimaxi.com/v1
# Embedding 保持 SiliconFlow（MiniMax 無 embedding 模型）
-e MOS_EMBEDDER_MODEL=BAAI/bge-m3
-e MOS_EMBEDDER_API_BASE=https://api.siliconflow.cn/v1
```

## lossless-claw 遷移步驟

在 `openclaw.json` 中：

```json
{
  "plugins": {
    "entries": {
      "lossless-claw": {
        "enabled": true,
        "config": {
          "summaryModel": "MiniMax-M2.7-highspeed",
          "summaryProvider": "minimax"
        }
      }
    }
  }
}
```

## LanceDB Pro 衰減調參

```json
{
  "retrieval": {
    "recencyHalfLifeDays": 14,
    "recencyWeight": 0.25
  }
}
```

- 14 天半衰期（接近 Ebbinghaus λ=0.05）
- 0.25 權重（從 0.15 上調，讓衰減更明顯）

## Update: Cognee MiniMax Migration Complete (2026-03-22 21:01)

Scott#1 found the solution:
1. **Merge system prompt into user message** (bypass MiniMax system role rejection)
2. **Add max_tokens control** (prevent reasoning tokens from consuming all capacity)
3. **Fix Cognee source bug** (`get_llm_client.py` CUSTOM provider missing endpoint)

### Final Cognee Config

```bash
-e LLM_API_KEY=<minimax-key>
-e LLM_MODEL=openai/MiniMax-M2.7-highspeed
-e LLM_PROVIDER=custom
-e LLM_ENDPOINT=https://api.minimaxi.com/v1
-e OPENAI_API_KEY=<minimax-key>
-e OPENAI_API_BASE=https://api.minimaxi.com/v1
```

### Adapter Patch (system→user merge)

```python
def _merge_system_into_user(messages):
    merged = []
    pending_system = []
    for msg in messages:
        if msg.get('role') == 'system':
            pending_system.append(msg.get('content', ''))
        else:
            if pending_system:
                sys_content = '\n'.join(pending_system)
                if msg.get('role') == 'user':
                    msg = dict(msg)
                    msg['content'] = sys_content + '\n\n' + msg.get('content', '')
                else:
                    merged.append({'role': 'user', 'content': sys_content})
                pending_system = []
            merged.append(msg)
    if pending_system:
        merged.append({'role': 'user', 'content': '\n'.join(pending_system)})
    return merged
```

### Verified: 96/96 tests passed, 5A+ certified
