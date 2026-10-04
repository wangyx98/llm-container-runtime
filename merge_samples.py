#!/usr/bin/env python3
"""
Combine several samples JSON files (e.g. multiple per-model,
per-timestamp files written by generate_llm_samples.py under
samples/generated/) into ONE file, so run_benchmark.py can evaluate
several models' generated solutions in a single pass and
compute_pass_at_1.py can show them side-by-side in one table.

Each input file is left untouched -- this only writes a new merged
file, so the individual per-run backups under samples/generated/ are
never modified or deleted.

Usage:
    # merge specific files
    python3 merge_samples.py \
        samples/generated/anthropic__claude-sonnet-4-5__2026-09-20_21-15-03.json \
        samples/generated/openai__gpt-4o__2026-09-20_21-40-11.json \
        samples/generated/huggingface__Qwen_Qwen2.5-Coder-32B-Instruct__2026-09-20_22-02-47.json \
        --out samples/generated/compare_2026-09-20.json

    # or merge every run under samples/generated/ in one shot
    python3 merge_samples.py samples/generated/*.json --out samples/generated/all_runs.json
    python3 merge_samples.py samples/generated --out samples/generated/all_runs.json   # same, a directory works too

    # rebuild one flat file from the per-case fixtures tree (e.g. for a tool that
    # still wants the old samples/llm_outputs.json)
    python3 merge_samples.py samples/fixtures --out samples/llm_outputs.json

Then:
    python3 run_benchmark.py --samples samples/generated/compare_2026-09-20.json
    python3 compute_pass_at_1.py --latest

If two input files both have a sample for the same (case_id, model), the
one from the file listed LATER on the command line wins (so, e.g., you
can pass an older then a newer run of the same model to keep only the
newer one) -- a warning is printed either way so an accidental collision
between two different models sharing a "model" label doesn't silently
lose data.
"""

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))  # so "src.xxx" imports work

from src.utils import samples_io  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="+",
                         help="samples JSON files and/or directories (every *.json below a "
                              "directory, in sorted order) to merge, in order")
    parser.add_argument("--out", required=True, help="path to write the merged samples file")
    args = parser.parse_args()

    merged: dict[tuple, dict] = {}
    order: list[tuple] = []

    out_resolved = Path(args.out).resolve()
    input_files: list[Path] = []
    try:
        for arg in args.inputs:
            files = samples_io.expand_sources([arg])
            if Path(arg).is_dir():
                # a directory that contains --out must not feed the previous merge back in
                files = [f for f in files if f.resolve() != out_resolved]
            input_files.extend(files)
    except samples_io.SampleLoadError as exc:
        parser.error(str(exc))

    for path in input_files:
        with open(path, "r", encoding="utf-8") as f:
            samples = json.load(f)

        for s in samples:
            key = (s["case_id"], s.get("model"))
            if key in merged:
                print(f"note: {path.name} overrides an earlier sample for "
                      f"case_id={key[0]!r} model={key[1]!r}", file=sys.stderr)
            else:
                order.append(key)
            merged[key] = s

    out_samples = [merged[key] for key in order]

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out_samples, f, indent=2, ensure_ascii=False)

    models = sorted({s.get("model") for s in out_samples})
    shown = models if len(models) <= 12 else f"{models[:6]} ... {models[-3:]}"
    print(f"merged {len(input_files)} file(s) -> {len(out_samples)} sample(s) across "
          f"{len(models)} model(s): {shown}")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
