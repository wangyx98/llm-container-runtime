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

    # run a specific named sample from samples/llm_outputs.json
    python3 run_single_case.py q61058619 --model cheating_allow_all_profile

    # run arbitrary ad-hoc shell code without touching samples/llm_outputs.json
    python3 run_single_case.py q61058619 --code "echo hello"

    # run the no-op baseline (empty code, to confirm the oracle correctly fails)
    python3 run_single_case.py q61058619 --model no_op_baseline
"""

import argparse
import importlib
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))

from src.cfg_reader import primary  # noqa: E402


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


def load_sample(case_id: str, category: str, model: str | None, code: str | None, samples_file: str) -> dict:
    if code is not None:
        return {"case_id": case_id, "category": category, "model": model or "adhoc", "code": code}

    with open(samples_file, "r", encoding="utf-8") as f:
        samples = json.load(f)

    matches = [s for s in samples if s["case_id"] == case_id]
    if not matches:
        raise ValueError(f"no samples found for case_id '{case_id}' in {samples_file}")

    if model:
        for s in matches:
            if s.get("model") == model:
                return s
        available = [s.get("model") for s in matches]
        raise ValueError(f"model '{model}' not found for {case_id}. Available: {available}")

    # default: prefer the reference_solution sample if present, else the first match
    for s in matches:
        if s.get("model") == "reference_solution":
            return s
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("case_id", help="e.g. q61058619")
    parser.add_argument("--model", default=None, help="which sample in llm_outputs.json to run (by model name)")
    parser.add_argument("--code", default=None, help="run this raw shell code instead of a sample from the JSON file")
    parser.add_argument("--config", default=str(REPO_ROOT / "conf" / "config.yaml"))
    parser.add_argument("--samples", default=None, help="overrides samples_file in config.yaml")
    args = parser.parse_args()

    cfg = primary.load(args.config)
    samples_file = args.samples or cfg.get("samples_file", "samples/llm_outputs.json")

    category = find_case_category(args.case_id)
    sample = load_sample(args.case_id, category, args.model, args.code, samples_file)

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
