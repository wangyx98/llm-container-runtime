#!/usr/bin/env python3
"""
One-time migration: split the single hand-written samples file
(samples/llm_outputs.json) into one JSON file per case, grouped by taxonomy
category:

    samples/fixtures/<category>/<case_id>.json

Each output file is a JSON list holding that case's samples in their original
order, and every sample is copied EXACTLY as it was (same four fields, same
values) -- nothing is rewritten, renamed or re-escaped.

After writing, the script reloads what it wrote and checks that the migration
was lossless: every one of the original samples comes back identical (compared
as parsed data, not as bytes), none is missing, none is extra, and each case's
samples are in the same order. It exits non-zero if anything differs.

The source file is never modified or deleted; once you are happy with the new
tree you can `git rm samples/llm_outputs.json` yourself (or keep it, see
`python3 merge_samples.py samples/fixtures --out samples/llm_outputs.json`,
which rebuilds it from the tree whenever a single file is wanted).

Usage:
    python3 migrate_samples.py                          # samples/llm_outputs.json -> samples/fixtures/
    python3 migrate_samples.py --src OLD.json --dst DIR
    python3 migrate_samples.py --force                  # overwrite files already in DIR
"""

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent


def dump(samples: list) -> str:
    # same style as the existing samples file: 2-space indent, non-ASCII kept as is
    return json.dumps(samples, indent=2, ensure_ascii=False) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--src", default=str(REPO_ROOT / "samples" / "llm_outputs.json"),
                        help="the single samples file to split (default: samples/llm_outputs.json)")
    parser.add_argument("--dst", default=str(REPO_ROOT / "samples" / "fixtures"),
                        help="directory to write <category>/<case_id>.json into (default: samples/fixtures)")
    parser.add_argument("--force", action="store_true",
                        help="overwrite per-case files that already exist in --dst")
    args = parser.parse_args()

    src = Path(args.src)
    dst = Path(args.dst)
    if not src.exists():
        parser.error(f"source file not found: {src}")

    with open(src, "r", encoding="utf-8") as f:
        original = json.load(f)
    if not isinstance(original, list) or not all(isinstance(s, dict) for s in original):
        parser.error(f"{src} is not a JSON list of sample objects")

    problems = []
    for i, s in enumerate(original):
        for key in ("case_id", "category", "model"):
            if not s.get(key):
                problems.append(f"entry #{i} has no '{key}': {json.dumps(s)[:120]}")
    seen = set()
    for s in original:
        key = (s.get("case_id"), s.get("model"))
        if key in seen:
            problems.append(f"duplicate sample for case_id={key[0]!r} model={key[1]!r}")
        seen.add(key)
    cats_of_case: dict[str, set] = {}
    for s in original:
        cats_of_case.setdefault(s.get("case_id"), set()).add(s.get("category"))
    for cid, cats in cats_of_case.items():
        if len(cats) > 1:
            problems.append(f"case {cid} has samples in several categories: {sorted(cats)}")
    if problems:
        print("cannot migrate, the source file has problems:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        sys.exit(1)

    # group by (category, case_id), keeping each case's samples in their original order
    groups: dict[tuple, list] = {}
    for s in original:
        groups.setdefault((s["category"], s["case_id"]), []).append(s)

    existing = sorted(dst / cat / f"{cid}.json" for (cat, cid) in groups if (dst / cat / f"{cid}.json").exists())
    if existing and not args.force:
        print("these files already exist (use --force to overwrite):", file=sys.stderr)
        for p in existing:
            print(f"  {p}", file=sys.stderr)
        sys.exit(1)

    written = []
    for (cat, cid), samples in sorted(groups.items()):
        out = dst / cat / f"{cid}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(dump(samples), encoding="utf-8")
        written.append(out)

    # ---- verify: read back only what was just written, compare as parsed data ----
    reloaded: dict[tuple, list] = {}
    for out in written:
        with open(out, "r", encoding="utf-8") as f:
            data = json.load(f)
        for s in data:
            reloaded.setdefault((s["category"], s["case_id"]), []).append(s)

    errors = []
    if set(reloaded) != set(groups):
        errors.append(f"cases differ: missing {sorted(set(groups) - set(reloaded))}, "
                      f"extra {sorted(set(reloaded) - set(groups))}")
    for key, expected in groups.items():
        got = reloaded.get(key, [])
        if got != expected:
            errors.append(f"{key[1]}: samples differ after the round trip "
                          f"(expected {[s['model'] for s in expected]}, got {[s['model'] for s in got]})")
    total_new = sum(len(v) for v in reloaded.values())
    if total_new != len(original):
        errors.append(f"sample count differs: {len(original)} before, {total_new} after")
    # every original sample must appear in the new tree exactly as it was
    flat_new = [s for key in sorted(reloaded) for s in reloaded[key]]
    for s in original:
        if s not in flat_new:
            errors.append(f"sample not found unchanged: {s['case_id']} / {s['model']}")

    per_cat: dict[str, list] = {}
    for (cat, cid), samples in sorted(groups.items()):
        per_cat.setdefault(cat, []).append((cid, len(samples)))
    print(f"split {len(original)} samples of {len(groups)} cases into {len(written)} files under {dst}/")
    for cat, items in sorted(per_cat.items()):
        print(f"  {cat}: {len(items)} cases, {sum(n for _, n in items)} samples")

    if errors:
        print("\nVERIFICATION FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)
    print(f"\nverified: all {len(original)} samples read back identical, none missing, none extra, "
          f"per-case order kept.")


if __name__ == "__main__":
    main()
