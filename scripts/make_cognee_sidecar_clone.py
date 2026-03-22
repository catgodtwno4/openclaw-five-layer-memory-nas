#!/usr/bin/env python3
"""
Clone cognee-openclaw into a non-memory-slot sidecar plugin.
This allows Cognee to coexist with memory-lancedb-pro.

Usage:
    python3 make_cognee_sidecar_clone.py [--force] [--source DIR] [--dest DIR]
"""
from __future__ import annotations
import argparse
import json
import shutil
from pathlib import Path


def patch_text(text: str) -> str:
    text = text.replace('id: "cognee-openclaw",', 'id: "cognee-sidecar-openclaw",')
    text = text.replace('name: "Memory (Cognee)",', 'name: "Cognee Sidecar",')
    text = text.replace('    kind: "memory",\n', '')
    text = text.replace('config.plugins.slots.memory = "cognee-openclaw";\n', '')
    text = text.replace('entries["cognee-openclaw"]', 'entries["cognee-sidecar-openclaw"]')
    return text


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=str(Path.home() / ".openclaw/extensions/cognee-openclaw"))
    ap.add_argument("--dest", default=str(Path.home() / ".openclaw/extensions/cognee-sidecar-openclaw"))
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    src, dst = Path(args.source), Path(args.dest)
    if not src.exists():
        raise SystemExit(f"Source not found: {src}")
    if dst.exists():
        if not args.force:
            raise SystemExit(f"Dest exists: {dst} (use --force)")
        shutil.rmtree(dst)

    shutil.copytree(src, dst)

    # Patch manifest
    m = dst / "openclaw.plugin.json"
    mj = json.loads(m.read_text())
    mj["id"] = "cognee-sidecar-openclaw"
    mj["name"] = "Cognee Sidecar"
    mj.pop("kind", None)
    m.write_text(json.dumps(mj, ensure_ascii=False, indent=2) + "\n")

    # Patch package.json
    p = dst / "package.json"
    pj = json.loads(p.read_text())
    pj["name"] = "@cognee/cognee-sidecar-openclaw"
    p.write_text(json.dumps(pj, ensure_ascii=False, indent=2) + "\n")

    # Patch runtime
    r = dst / "dist/src/plugin.js"
    r.write_text(patch_text(r.read_text()))

    # Patch client.js — flatten nested search results + dedup + truncate
    c = dst / "dist/src/client.js"
    ct = c.read_text()
    old_normalize = '''function normalizeSearchResults(data) {
    if (Array.isArray(data)) {
        return data.map((item, index) => {
            if (typeof item === "string") {
                return { id: `result-${index}`, text: item, score: 1 };
            }
            if (item && typeof item === "object") {
                const record = item;
                return {
                    id: typeof record.id === "string" ? record.id : `result-${index}`,
                    text: typeof record.text === "string" ? record.text : JSON.stringify(record),
                    score: typeof record.score === "number" ? record.score : 1,
                    metadata: record.metadata,
                };
            }
            return { id: `result-${index}`, text: String(item), score: 1 };
        });
    }
    if (data && typeof data === "object" && "results" in data) {
        return normalizeSearchResults(data.results);
    }
    return [];
}'''
    new_normalize = '''function normalizeSearchResults(data) {
    if (Array.isArray(data)) {
        const flat = [];
        for (const item of data) {
            if (item && typeof item === "object" && Array.isArray(item.search_result)) {
                for (const sr of item.search_result) flat.push(sr);
            } else {
                flat.push(item);
            }
        }
        const seen = new Set();
        return flat.map((item, index) => {
            if (typeof item === "string") {
                return { id: `result-${index}`, text: item.slice(0, 800), score: 1 };
            }
            if (item && typeof item === "object") {
                const record = item;
                let text = typeof record.text === "string" ? record.text : JSON.stringify(record);
                const source = record.metadata?.source || record.id || text.slice(0, 100);
                if (seen.has(source)) return null;
                seen.add(source);
                text = text.slice(0, 800);
                return {
                    id: typeof record.id === "string" ? record.id : `result-${index}`,
                    text,
                    score: typeof record.score === "number" ? record.score : 1,
                    metadata: record.metadata,
                };
            }
            return { id: `result-${index}`, text: String(item).slice(0, 800), score: 1 };
        }).filter(Boolean);
    }
    if (data && typeof data === "object" && "results" in data) {
        return normalizeSearchResults(data.results);
    }
    return [];
}'''
    if old_normalize in ct:
        ct = ct.replace(old_normalize, new_normalize)
        c.write_text(ct)
        print("Patched client.js normalizeSearchResults")

    print(f"Created sidecar: {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
