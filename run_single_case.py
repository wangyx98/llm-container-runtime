#!/usr/bin/env python3
"""
Run the full 5-stage lifecycle (cleanup -> setup -> precondition -> LLM code
-> oracle -> cleanup) for exactly ONE case, without touching the other
cases and without needing to know/type its taxonomy category.

This does NOT duplicate any test logic — it just calls the same
run_tests(sample, cfg) function that run_benchmark.py calls in bulk,
for a single sample.

Usage:
    # run the case's reference_solution sample (default if present)
    python3 run_single_case.py q61058619

    # run a specific named sample from samples/fixtures/<category>/q61058619.json
    python3 run_single_case.py q61058619 --model cheating_allow_all_profile

    # see which sample names the case has
    python3 run_single_case.py q61058619 --list

    # run arbitrary ad-hoc shell code without touching any samples file
    python3 run_single_case.py q61058619 --code "echo hello"

    # run the no-op baseline (empty code, to confirm the oracle correctly fails)
    python3 run_single_case.py q61058619 --model no_op_baseline

    # take the sample from a real model's file (or directory) instead of the fixtures
    python3 run_single_case.py q61058619 --model gpt-4o \\
        --samples samples/generated/openai__gpt-4o__2026-09-21_12-32-43.json

(There is no --exclude here: this script runs exactly one case. To leave a case
out of a bulk run use `run_benchmark.py --exclude q72392812`.)
"""

import argparse
import importlib
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))

from src.cfg_reader import primary  # noqa: E402
from src.utils import samples_io  # noqa: E402


def find_case_category(case_id: str) -> str:
    """Search src/test_suites/*/<case_id>.py so the caller never has to
    type the taxonomy category by hand."""
    test_suites_dir = REPO_ROOT / "src" / "test_suites"
    matches = list(test_suites_dir.glob(f"*/{case_id}.py"))
    if not matches:
        raise FileNotFoundError(
            f"no src/test_suites/<category>/{case_id}.py found under {test_suites_dir}"
        )
    if len(matches) > 1:
        raise RuntimeError(f"case_id '{case_id}' found in multiple categories: {matches}")
    return matches[0].parent.name


def load_case_samples(case_id: str, samples_sources: list) -> list[dict]:
    """All samples of one case, from the given files/directories. In the fixtures
    tree only that case's own file is opened."""
    try:
        samples = samples_io.load_samples(samples_sources, only_cases={case_id})
    except samples_io.SampleLoadError as exc:
        raise SystemExit(f"error: {exc}")
    return [s for s in samples if s["case_id"] == case_id]


def load_sample(case_id: str, category: str, model: str | None, code: str | None, samples_sources: list) -> dict:
    if code is not None:
        return {"case_id": case_id, "category": category, "model": model or "adhoc", "code": code}

    matches = load_case_samples(case_id, samples_sources)
    if not matches:
        raise ValueError(f"no samples found for case_id '{case_id}' in {[str(s) for s in samples_sources]}")

    if model:
        for s in matches:
            if s.get("model") == model:
                return samples_io.strip_private(s)
        available = [s.get("model") for s in matches]
        raise ValueError(f"model '{model}' not found for {case_id}. Available: {available}")

    # default: prefer the reference_solution sample if present, else the first match
    for s in matches:
        if s.get("model") == "reference_solution":
            return samples_io.strip_private(s)
    return samples_io.strip_private(matches[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("case_id", help="e.g. q61058619")
    parser.add_argument("--model", default=None, help="which sample of the case to run (by its model/sample name)")
    parser.add_argument("--code", default=None, help="run this raw shell code instead of a stored sample")
    parser.add_argument("--list", action="store_true", help="only list the sample names this case has, then exit")
    parser.add_argument("--config", default=str(REPO_ROOT / "conf" / "config.yaml"))
    parser.add_argument("--samples", nargs="+", default=None, metavar="FILE_OR_DIR",
                         help="where to read samples from: JSON file(s) and/or directories. "
                              "Overrides samples_path in config.yaml (default: samples/fixtures)")
    args = parser.parse_args()

    cfg = primary.load(args.config)
    samples_sources = args.samples or [samples_io.default_source(cfg)]

    category = find_case_category(args.case_id)

    if args.list:
        found = load_case_samples(args.case_id, samples_sources)
        print(f"{args.case_id} ({category}): {len(found)} sample(s) in {[str(s) for s in samples_sources]}")
        for s in found:
            print(f"  {s.get('model')}   [{s['_kind']}]")
        sys.exit(0)

    sample = load_sample(args.case_id, category, args.model, args.code, samples_sources)

    print(f"=== Running {args.case_id} (category: {category}) — model: {sample.get('model', 'adhoc')} ===\n")

    module = importlib.import_module(f"src.test_suites.{category}.{args.case_id}")
    cases, error_message = module.run_tests(sample, cfg)

    print("\n=== Result ===")
    for key, value in cases.items():
        # keep long stdout/stderr fields from flooding the terminal
        if isinstance(value, str) and len(value) > 300:
            value = value[:300] + "... (truncated)"
        print(f"  {key}: {value}")

    if error_message:
        print(f"\nerror_message: {error_message}")

    status = "PASS" if cases.get("oracle_passed") else "FAIL"
    print(f"\n{args.case_id} [{sample.get('model', 'adhoc')}] -> {status}")

    sys.exit(0 if cases.get("oracle_passed") else 1)


if __name__ == "__main__":
    main()
