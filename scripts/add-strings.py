#!/usr/bin/env python3
"""Adds or updates French translations in Rowster/Resources/Localizable.xcstrings.

Usage: scripts/add-strings.py < pairs.tsv
Each input line is `English key<TAB>French value`. Lines that are empty or start with `#` are ignored.
Write `\\n` for a line break. The key must be exactly what the compiler extracts (`%lld rows`, `Open %@`).
"""
import json
import sys

PATH = "Rowster/Resources/Localizable.xcstrings"

with open(PATH, encoding="utf-8") as handle:
    catalog = json.load(handle)

added = updated = 0
for number, line in enumerate(sys.stdin, 1):
    line = line.rstrip("\n")
    if not line.strip() or line.startswith("#"):
        continue
    if "\t" not in line:
        sys.exit(f"add-strings: line {number} has no tab: {line!r}")
    key, value = (part.replace("\\n", "\n") for part in line.split("\t", 1))
    if not value:
        sys.exit(f"add-strings: line {number} has an empty French value")
    entry = catalog["strings"].setdefault(key, {})
    unit = {"state": "translated", "value": value}
    previous = entry.get("localizations", {}).get("fr", {}).get("stringUnit")
    if previous == unit:
        continue
    if previous is None:
        added += 1
    else:
        updated += 1
    entry.setdefault("localizations", {})["fr"] = {"stringUnit": unit}

with open(PATH, "w", encoding="utf-8") as handle:
    json.dump(catalog, handle, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
    handle.write("\n")

print(f"add-strings: {added} added, {updated} updated, {len(catalog['strings'])} keys in total")
