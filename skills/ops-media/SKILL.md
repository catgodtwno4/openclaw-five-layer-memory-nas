---
name: ops-media
description: Rules for sending images, files, and media to users via Telegram/messaging. Use when screenshots, files, or media need to be delivered to the user.
---

# Media Delivery Rules

## Sending Images to User

**ALWAYS use MEDIA: tag to send images in Telegram/messaging.**

```
MEDIA:./filename.jpg
```

### Rules:
1. **Use relative path** from workspace: `MEDIA:./filename.jpg`
2. **NEVER use absolute paths** like `MEDIA:/Users/...` — they are blocked
3. **NEVER use ~ paths** like `MEDIA:~/...` — they are blocked
4. **Copy file to workspace first** if it's elsewhere:
   ```bash
   cp /tmp/screenshot.jpg ~/.openclaw/workspace/screenshot.jpg
   ```
5. **Always send the image immediately** — don't wait for user to ask twice
6. **Include caption text** in the same message (not separate)
7. **If screenshot fails**, explain what happened and retry, don't just say "see above"

### Screenshot → Send Flow:
```bash
# 1. Capture
peekaboo image --app "Google Chrome" --path /tmp/shot.jpg

# 2. Copy to workspace
cp /tmp/shot.jpg ~/.openclaw/workspace/shot.jpg

# 3. Send (in your reply text)
MEDIA:./shot.jpg
Caption text here
```

### Common Mistakes to AVOID:
- ❌ Using `Read` tool to "show" an image — user sees nothing in Telegram
- ❌ Saying "截圖在上面" — image was NOT sent to Telegram
- ❌ Forgetting to copy to workspace before MEDIA: tag
- ❌ Sending MEDIA: with absolute path

## Sending Files

Same rules apply. Copy to workspace, use relative path:
```
MEDIA:./report.pdf
```

## Multiple Images

Send each with its own MEDIA: tag and caption.

## All Channels — Same Rules

This applies to **ALL messaging channels**:
- **Telegram** ✅
- **企業微信 (WeCom)** ✅
- **飛書 (Feishu/Lark)** ✅
- **Any other channel** ✅

**NEVER send just a file path or URL** — always send the actual file via MEDIA: tag.

### ❌ Wrong (all channels):
```
截圖在 /tmp/screenshot.jpg
看這個：~/.openclaw/workspace/report.pdf
```

### ✅ Correct (all channels):
```
MEDIA:./screenshot.jpg
這是截圖，顯示了...

MEDIA:./report.pdf
報告已生成，包含...
```
