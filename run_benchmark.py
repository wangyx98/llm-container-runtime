#!/usr/bin/env python3
"""
Generic driver: reads a list of LLM-generated samples, dispatches each one
to its matching test_suites/<category>/<case_id>.py module, and writes the
aggregated pass/fail results to a timestamped results folder.

Usage:
    python run_benchmark.py                       # uses conf/config.yaml defaults
    python run_benchmark.py --samples samples/llm_outputs.json
    python run_benchmark.py --config conf/config.yaml
"""

import argparse
import csv
import importlib
import json
import sys
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))  # so "src.xxx" imports work

from src.cfg_reader import primary  # noqa: E402


def load_test_module(category: str, case_id: str):
    module_path = f"src.test_suites.{category}.{case_id}"
    return importlib.import_module(module_path)


def run_all(samples_path: str, cfg: dict, exclude_ids: set[str] | None = None) -> list[dict]:
    with open(samples_path, "r", encoding="utf-8") as f:
        samples = json.load(f)

    exclude_ids = exclude_ids or set()
    if exclude_ids:
        skipped = [s["case_id"] for s in samples if s["case_id"] in exclude_ids]
        samples = [s for s in samples if s["case_id"] not in exclude_ids]
        if skipped:
            print(f"skipping {len(skipped)} sample(s) for excluded case(s): {skipped}\n")

    results = []
    for sample in samples:
        case_id = sample["case_id"]
        category = sample.get("category")
        model = sample.get("model", "unknown")

        if not category:
            results.append({
                "case_id": case_id,
                "category": None,
                "model": model,
                "error_message": "sample missing required 'category' field "
                                  "(must be one of: compatibility, configuration, "
                                  "filesystem, isolation, networking, diagnostics)",
            })
            continue

        try:
            module = load_test_module(category, case_id)
            cases, error_message = module.run_tests(sample, cfg)
        except Exception as exc:  # keep one bad sample from killing the run
            cases, error_message = {}, f"driver exception: {exc}"

        row = {
            "case_id": case_id,
            "category": category,
            "model": model,
            "error_message": error_message,
            **cases,
        }
        results.append(row)

        status = "PASS" if cases.get("oracle_passed") else "FAIL"
        print(f"[{case_id}] model={model} -> {status}")

    return results


def write_csv(results: list[dict], out_path: Path):
    if not results:
        print("no results to write")
        return

    out_path.parent.mkdir(parents=True, exist_ok=True)

    # union of all keys across rows, since different cases may report
    # different fields
    fieldnames: list[str] = []
    for row in results:
        for key in row.keys():
            if key not in fieldnames:
                fieldnames.append(key)

    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)

    print(f"\nwrote {len(results)} rows to {out_path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=str(REPO_ROOT / "conf" / "config.yaml"))
    parser.add_argument("--samples", default=None, help="overrides samples_file in config.yaml")
    parser.add_argument("--exclude", default=None,
                         help="comma-separated case_id(s) to skip, e.g. --exclude q72392812 "
                              "to skip a case whose reference solution is "
                              "architecture-specific (e.g. gVisor/runsc x86_64-only) and "
                              "can't run on this machine")
    args = parser.parse_args()

    cfg = primary.load(args.config)
    samples_file = args.samples or cfg.get("samples_file", "samples/llm_outputs.json")
    exclude_ids = {c.strip() for c in args.exclude.split(",")} if args.exclude else set()

    results = run_all(samples_file, cfg, exclude_ids=exclude_ids)

    # results/<timestamp>/results.csv — never overwrite a previous run
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    results_dir = REPO_ROOT / cfg.get("results_dir", "results") / timestamp
    write_csv(results, results_dir / "results.csv")


if __name__ == "__main__":
    main()
