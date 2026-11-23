#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Audit local English source keys against OCR pool readings without exporting game text.

Usage: python3 tools/packs/ocr_match_audit.py ROWS.jsonl POOL.json [--out REPORT.json]

ROWS may come from extract.py or other local sources; POOL is a {"lines": [...]}
export or the JSON array returned by a D1/wrangler read-only query.

This is an English-key preflight, not a translation or runtime coverage test.
In particular, replacing input-icon tags with whitespace is a diagnostic:
on-screen controller icons may change OCR layout or remove adjacent spaces.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as c
from atomic_json import dump_atomic

# Non-textual controller/map icon tags; do NOT remove ~1~ dynamic-value tokens.
ICONS = re.compile(r"~(?:INPUT_[^~\s]+|BLIP_[^~\s]+)~", re.I)
DYNAMIC = re.compile(r"~\d+[a-z$]?~", re.I)
# Only fixed category names reach the counts report; custom metadata can be story spoilers.
KNOWN_CATEGORIES = frozenset({
    "dialogue", "subtitle", "ui", "item", "description", "tutorial",
    "minigame", "menu", "system",
})
SPEAKER = re.compile(r"^\s*[A-Z][A-Za-z.'’\-]*(?:\s+[A-Z][A-Za-z.'’\-]*){0,3}\s*[:•]\s+")


def source_units(row):
    if not isinstance(row, dict) or not isinstance(row.get("text"), str):
        raise ValueError("source rows must contain string text")
    original = row["text"]
    sentences = row.get("sents")
    if sentences is None:
        sentences = c.sentences(original)
    if not isinstance(sentences, list) or not all(isinstance(s, str) for s in sentences):
        raise ValueError("sents must be a list of strings")
    return [original, *sentences]


def pool_lines(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(value, dict) and isinstance(value.get("lines"), list):
        rows = value["lines"]
    elif isinstance(value, list) and all(
            isinstance(page, dict) and page.get("success") is not False
            and isinstance(page.get("results"), list) for page in value):
        rows = [line for page in value for line in page["results"]]
    else:
        raise ValueError("expected a pool export with lines or D1 results")
    if not all(isinstance(row, dict) and isinstance(row.get("text"), str) for row in rows):
        raise ValueError("every OCR line must contain string text")
    return rows


def audit(rows_path, pool_path):
    exact_keys = set()
    icon_removed_keys = set()
    by_category = Counter()
    source_count = icon_count = dynamic_count = 0

    with Path(rows_path).open(encoding="utf-8") as stream:
        for raw in stream:
            if not raw.strip():
                continue
            row = json.loads(raw)
            units = source_units(row)
            source_count += 1
            category = row.get("category") or "unspecified"
            if not isinstance(category, str):
                category = "other"
            elif category not in KNOWN_CATEGORIES and category != "unspecified":
                category = "other"
            by_category[category] += 1
            icon_count += int(bool(ICONS.search(row["text"])))
            dynamic_count += int(bool(DYNAMIC.search(row["text"])))
            for unit in units:
                key = c.key(unit)
                if key:
                    exact_keys.add(key)
                without_icons = ICONS.sub(" ", unit)
                if without_icons != unit:
                    alternative = c.key(without_icons)
                    if alternative and alternative != key:
                        icon_removed_keys.add(alternative)

    counts = Counter()
    pool = pool_lines(pool_path)
    for line in pool:
        value = line["text"]
        speaker = SPEAKER.match(value)
        if speaker:
            value = value[speaker.end():]
        key = c.key(value)
        if key and key in exact_keys:
            counts["exact_key_candidates"] += 1
        elif key and key in icon_removed_keys:
            counts["input_icon_only_candidates"] += 1
        else:
            counts["unmatched"] += 1

    return {
        "source_rows": source_count,
        "source_unique_exact_keys": len(exact_keys),
        "source_rows_with_input_icons": icon_count,
        "source_rows_with_dynamic_fields": dynamic_count,
        "source_by_category": dict(sorted(by_category.items())),
        "ocr_lines": len(pool),
        "exact_key_candidates": counts["exact_key_candidates"],
        "input_icon_only_candidates": counts["input_icon_only_candidates"],
        "unmatched": counts["unmatched"],
        "runtime_coverage_estimated": False,
        "note": "English-key preflight only. Icon-stripped candidates need real-screen review; no translation or fuzzy matching is verified.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rows", help="local English rows.jsonl, never uploaded")
    parser.add_argument("pool", help="local OCR pool JSON/D1 export, never uploaded")
    parser.add_argument("--out", help="write a counts-only JSON report atomically; default stdout")
    args = parser.parse_args()
    try:
        summary = audit(args.rows, args.pool)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    if args.out:
        dump_atomic(summary, args.out, ensure_ascii=False, indent=2)
    else:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
