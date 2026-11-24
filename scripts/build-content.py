#!/usr/bin/env python3
"""Build a static MuseFrame editorial edition. Upload the resulting JSON at a stable URL."""
import argparse
import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile

root = Path(__file__).resolve().parents[1] / "MuseFrame"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--revision", type=int, required=True, help="Increasing positive publication number")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if args.revision < 1:
    parser.error("revision must be positive")
document = {"schemaVersion": 1, "revision": args.revision}
for key, path in {"artworks": "Data/SeedData/seed.json", "history": "Resources/ArtHistory/art_history_curated.json",
                  "guides": "Resources/ArtHistory/artwork_guides_zh.json"}.items():
    document[key] = json.loads((root / path).read_text())
args.output.parent.mkdir(parents=True, exist_ok=True)
with NamedTemporaryFile(mode="w", encoding="utf-8", dir=args.output.parent, delete=False) as temp:
    json.dump(document, temp, ensure_ascii=False, separators=(",", ":"))
os.chmod(temp.name, 0o644)
os.replace(temp.name, args.output)
