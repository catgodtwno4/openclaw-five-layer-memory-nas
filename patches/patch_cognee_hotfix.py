#!/usr/bin/env python3
"""
Patch Cognee embedding files to:
1. Suppress `dimensions` parameter (SiliconFlow doesn't support it)
2. Change default embedding_dimensions from 3072 to 1024 (for bge-m3)

Usage:
    python3 patch_cognee_hotfix.py <LiteLLMEmbeddingEngine.py> <config.py>
"""
from pathlib import Path
import sys

if len(sys.argv) < 3:
    print("Usage: python3 patch_cognee_hotfix.py <engine_file> <config_file>")
    sys.exit(1)

engine_file = Path(sys.argv[1])
config_file = Path(sys.argv[2])

# Patch 1: Suppress dimensions
text = engine_file.read_text()
old = '# Pass through target embedding dimensions when supported\n                    if self.dimensions is not None:\n                        embedding_kwargs["dimensions"] = self.dimensions'
if old in text:
    text = text.replace(old, '# OpenClaw hotfix: dimensions suppressed for SiliconFlow compatibility')
    engine_file.write_text(text)
    print(f"Patched dimensions suppression: {engine_file}")
else:
    print(f"Already patched or pattern not found: {engine_file}")

# Patch 2: Default 3072 → 1024
text = config_file.read_text()
if 'embedding_dimensions: Optional[int] = 3072' in text:
    text = text.replace(
        'embedding_dimensions: Optional[int] = 3072',
        'embedding_dimensions: Optional[int] = 1024'
    )
    config_file.write_text(text)
    print(f"Patched default dims 3072→1024: {config_file}")
else:
    print(f"Already patched or not found: {config_file}")
