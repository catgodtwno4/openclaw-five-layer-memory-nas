#!/usr/bin/env python3
"""
Patch MemOS neo4j_community.py to fix Map{} type error on Neo4j 5.26.

Usage:
    python3 patch_neo4j_community.py /path/to/neo4j_community.py
"""
from pathlib import Path
import sys

if len(sys.argv) < 2:
    print("Usage: python3 patch_neo4j_community.py <file_path>")
    sys.exit(1)

f = Path(sys.argv[1])
text = f.read_text()

# Add json import if missing
if "import json" not in text:
    text = "import json\n" + text

# Add flatten helper before class definition
helper = '''
def _flatten_metadata_for_neo4j(meta):
    """Flatten metadata so all values are Neo4j-safe primitives or arrays of primitives."""
    import json as _json
    if not isinstance(meta, dict):
        return meta
    result = {}
    for k, v in meta.items():
        if v is None:
            result[k] = ""
        elif isinstance(v, (str, int, float, bool)):
            result[k] = v
        elif isinstance(v, list):
            result[k] = [str(item) if not isinstance(item, (str, int, float, bool)) else item for item in v]
        elif isinstance(v, dict):
            result[k] = _json.dumps(v, ensure_ascii=False)
        else:
            result[k] = str(v)
    return result

'''

if "def _flatten_metadata_for_neo4j" not in text:
    text = text.replace(
        "class Neo4jCommunityGraphDB(Neo4jGraphDB):",
        helper + "class Neo4jCommunityGraphDB(Neo4jGraphDB):"
    )
    print("Added _flatten_metadata_for_neo4j function")

# Patch metadata reference
old = '                "metadata": node["metadata"],'
new = '                "metadata": _flatten_metadata_for_neo4j(node["metadata"]),'
if old in text:
    text = text.replace(old, new)
    print("Patched metadata reference")

f.write_text(text)
print(f"Done: {f}")
