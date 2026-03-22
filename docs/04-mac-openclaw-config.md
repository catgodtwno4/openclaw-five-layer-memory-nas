# Mac 端 OpenClaw 配置

## 1. 安裝 Cognee 插件

```bash
openclaw plugins install @cognee/cognee-openclaw
```

> ⚠️ 安裝會搶佔 memory slot！需要做 sidecar 克隆。

## 2. 建立 Cognee Sidecar 克隆

Cognee 插件聲明 `kind: "memory"`，會和 LanceDB Pro 衝突。需要克隆成不佔 slot 的 sidecar：

```bash
python3 scripts/make_cognee_sidecar_clone.py --force
```

或手動：

```bash
# 複製
cp -r ~/.openclaw/extensions/cognee-openclaw ~/.openclaw/extensions/cognee-sidecar-openclaw

# 修改 manifest
cd ~/.openclaw/extensions/cognee-sidecar-openclaw
# openclaw.plugin.json: id → cognee-sidecar-openclaw, 移除 kind
# package.json: name → @cognee/cognee-sidecar-openclaw
# dist/src/plugin.js: id 改名, 移除 kind: "memory"
```

## 3. Patch Sidecar（防上下文溢出）

### client.js — 展平嵌套搜索結果 + 去重 + 截斷

Cognee search 返回 `{dataset_id, search_result: [...]}` 嵌套格式，需要展平。
每條 chunk 截斷到 800 字符，按源文件去重。

見 `patches/patch_sidecar_client.js.patch`

### plugin.js — 純文本輸出 + 總量上限

改 JSON.stringify 為 `- [score] text` 純文本格式。
總注入量上限 3000 字符。

見 `patches/patch_sidecar_plugin.js.patch`

## 4. 修改 openclaw.json

```json
{
  "plugins": {
    "slots": {
      "memory": "memory-lancedb-pro"
    },
    "allow": [
      "lossless-claw",
      "memory-lancedb-pro",
      "cognee-sidecar-openclaw",
      "telegram"
    ],
    "entries": {
      "cognee-openclaw": {
        "enabled": false
      },
      "cognee-sidecar-openclaw": {
        "enabled": true,
        "config": {
          "baseUrl": "http://YOUR_NAS_IP:8766",
          "datasetName": "openclaw-YOUR_MACHINE-v1",
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
          "password": "YOUR_COGNEE_PASSWORD"
        }
      }
    }
  }
}
```

## 5. 驗證配置

```bash
openclaw config validate
openclaw gateway restart
```

確認輸出包含：
- `memory-lancedb-pro@x.x.x: plugin registered`
- `cognee-sidecar-openclaw: loaded`

## 共存架構

```
plugins.slots.memory = "memory-lancedb-pro"  ← 佔 slot
cognee-openclaw = disabled                    ← 原版關閉
cognee-sidecar-openclaw = enabled             ← 不佔 slot，lifecycle hooks 仍工作
```
