#!/usr/bin/env python3
"""
Generic driver: reads samples, dispatches each one to its matching
test_suites/<category>/<case_id>.py module, and writes the aggregated
pass/fail results to a timestamped results folder.

Samples come from two places (see src/utils/samples_io.py):
  samples/fixtures/<category>/<case_id>.json   hand-written samples that test the
                                               oracles (reference_solution, no_op_baseline,
                                               naive_*, cheat_*, alt_valid_*)
  samples/generated/*.json                     real LLM outputs from generate_llm_samples.py
Each row of results.csv records which of the two it was in `sample_kind`
("fixture" or "model"), so compute_pass_at_1.py can score real models without
the hand-written samples mixed in.

Usage:
    python run_benchmark.py                          # conf/config.yaml default (samples/fixtures)
    python run_benchmark.py --fixtures               # every hand-written sample
    python run_benchmark.py --generated              # every real-model sample under samples/generated/
    python run_benchmark.py --samples FILE_OR_DIR [FILE_OR_DIR ...]
    python run_benchmark.py --fixtures --category isolation
    python run_benchmark.py --fixtures --case q66478456,q65393959
    python run_benchmark.py --fixtures --model "reference_solution,no_op_baseline"   # smoke run
    python run_benchmark.py --fixtures --model "naive_*"
    python run_benchmark.py --exclude q72392812      # leave a case out
    python run_benchmark.py --config conf/config.yaml
"""

import argparse
import csv
import importlib
import sys
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))  # so "src.xxx" imports work

from src.cfg_reader import primary  # noqa: E402
from src.utils import samples_io  # noqa: E402


def load_test_module(category: str, case_id: str):
    module_path = f"src.test_suites.{category}.{case_id}"
    return importlib.import_module(module_path)


def run_all(samples: list[dict], cfg: dict) -> list[dict]:
    results = []
    for loaded in samples:
        sample_kind = loaded.get("_kind", samples_io.KIND_MODEL)
        sample = samples_io.strip_private(loaded)   # test suites see the sample exactly as stored
        case_id = sample["case_id"]
        category = sample.get("category")
        model = sample.get("model", "unknown")

        if not category:
            results.append({
                "case_id": case_id,
                "category": None,
                "model": model,
                "sample_kind": sample_kind,
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
            "sample_kind": sample_kind,
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
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=str(REPO_ROOT / "conf" / "config.yaml"))
    parser.add_argument("--samples", nargs="+", default=None, metavar="FILE_OR_DIR",
                         help="samples to run: one or more JSON files and/or directories (every "
                              "*.json below a directory is read). Overrides samples_path in config.yaml")
    parser.add_argument("--fixtures", action="store_true",
                         help="add every hand-written sample under samples/fixtures/")
    parser.add_argument("--generated", action="store_true",
                         help="add every real-model sample under samples/generated/ "
                              "(for the same case and model, the later file wins)")
    parser.add_argument("--case", default=None,
                         help="only these case_id(s), comma-separated, e.g. --case q66478456,q65393959")
    parser.add_argument("--category", default=None,
                         help="only these categories, comma-separated, e.g. --category isolation")
    parser.add_argument("--model", default=None,
                         help="only samples whose model name matches, comma-separated names or "
                              "patterns, e.g. --model 'reference_solution,no_op_baseline' or --model 'naive_*'")
    parser.add_argument("--exclude", default=None,
                         help="comma-separated case_id(s) to skip, e.g. --exclude q72392812 "
                              "to skip a case whose reference solution is "
                              "architecture-specific (e.g. gVisor/runsc x86_64-only) and "
                              "can't run on this machine")
    args = parser.parse_args()

    cfg = primary.load(args.config)

    sources = list(args.samples or [])
    if args.fixtures:
        sources.append(samples_io.FIXTURES_DIR)
    if args.generated:
        sources.append(samples_io.GENERATED_DIR)
    if not sources:
        sources = [samples_io.default_source(cfg)]

    try:
        samples = samples_io.load_samples(sources)
    except samples_io.SampleLoadError as exc:
        parser.exit(2, f"error: {exc}\n")

    total = len(samples)
    exclude_ids = {c.strip() for c in args.exclude.split(",")} if args.exclude else set()
    if exclude_ids:
        skipped = [s["case_id"] for s in samples if s["case_id"] in exclude_ids]
        if skipped:
            print(f"skipping {len(skipped)} sample(s) for excluded case(s): {sorted(set(skipped))}\n")
    samples = samples_io.filter_samples(samples, cases=args.case, categories=args.category,
                                        models=args.model, exclude=args.exclude)
    if not samples:
        parser.exit(2, f"error: no samples left to run (loaded {total} from "
                       f"{[str(s) for s in sources]} before filtering)\n")
    print(f"running {len(samples)} sample(s) (of {total} loaded) from {[str(s) for s in sources]}\n")

    results = run_all(samples, cfg)

    passed = sum(1 for r in results if r.get("oracle_passed") is True)
    print(f"\n{len(results)} sample(s) run: {passed} passed the oracle, {len(results) - passed} did not")

    # results/<timestamp>/results.csv — never overwrite a previous run
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    results_dir = REPO_ROOT / cfg.get("results_dir", "results") / timestamp
    write_csv(results, results_dir / "results.csv")


if __name__ == "__main__":
    main()
