#!/usr/bin/env python3
"""
Summarize a results.csv (written by run_benchmark.py) into a pass@1 table:
one row per model, showing how many of the cases it attempted actually
passed the postcondition oracle.

pass@1 here means exactly what it sounds like for this harness: each
sample in samples_file is ONE model-generated attempt at ONE case (no
retries, no majority voting across multiple generations) -- so
"oracle_passed" per (case_id, model) row IS the pass@1 signal for that
attempt, and this script just aggregates it into a per-model rate:

    pass@1(model) = (# cases where oracle_passed == True) / (# cases attempted)

If you want a stricter view that also requires setup/precondition to have
gone cleanly (i.e. excludes cases where the harness itself misbehaved
rather than the model's solution being wrong), the --strict flag also
requires setup_ok and precondition_passed to be True.

Usage:
    python3 compute_pass_at_1.py results/2026-09-20_12-00-00/results.csv
    python3 compute_pass_at_1.py results/2026-09-20_12-00-00/results.csv --strict
    python3 compute_pass_at_1.py results/2026-09-20_12-00-00/results.csv --out summary.csv

    # summarize the most recently written results.csv without typing the path
    python3 compute_pass_at_1.py --latest
"""

import argparse
import csv
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent


def _to_bool(value) -> bool:
    """results.csv stores Python bool reprs as the strings 'True'/'False'
    (DictWriter just calls str() on whatever run_benchmark.py put there)."""
    return str(value).strip().lower() == "true"


def find_latest_results_csv(results_dir: Path) -> Path:
    candidates = sorted(results_dir.glob("*/results.csv"), key=lambda p: p.stat().st_mtime)
    if not candidates:
        raise FileNotFoundError(f"no results.csv found under {results_dir}/*/results.csv")
    return candidates[-1]


def summarize(csv_path: Path, strict: bool, exclude_ids: set[str] | None = None) -> list[dict]:
    with open(csv_path, "r", encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))

    exclude_ids = exclude_ids or set()
    if exclude_ids:
        skipped = [r.get("case_id") for r in rows if r.get("case_id") in exclude_ids]
        rows = [r for r in rows if r.get("case_id") not in exclude_ids]
        if skipped:
            print(f"excluding {len(skipped)} row(s) for case(s): {skipped}\n")

    by_model: dict[str, dict] = {}
    for row in rows:
        model = row.get("model") or "unknown"
        bucket = by_model.setdefault(model, {"model": model, "attempted": 0, "passed": 0, "cases": []})
        bucket["attempted"] += 1

        passed = _to_bool(row.get("oracle_passed"))
        if strict:
            passed = passed and _to_bool(row.get("setup_ok")) and _to_bool(row.get("precondition_passed"))

        if passed:
            bucket["passed"] += 1
        else:
            bucket["cases"].append(row.get("case_id"))

    summary = []
    for model, bucket in sorted(by_model.items()):
        attempted = bucket["attempted"]
        passed = bucket["passed"]
        rate = (passed / attempted) if attempted else 0.0
        summary.append({
            "model": model,
            "attempted": attempted,
            "passed": passed,
            "pass@1": f"{rate:.4f}",
            "pass@1_pct": f"{rate * 100:.1f}%",
            "failed_cases": ";".join(c for c in bucket["cases"] if c),
        })
    return summary


def print_table(summary: list[dict]):
    if not summary:
        print("no rows to summarize")
        return

    headers = ["model", "attempted", "passed", "pass@1_pct"]
    widths = [max(len(h), max((len(str(row[h])) for row in summary), default=0)) for h in headers]

    def fmt_row(values):
        return "  ".join(str(v).ljust(w) for v, w in zip(values, widths))

    print(fmt_row(headers))
    print(fmt_row(["-" * w for w in widths]))
    for row in summary:
        print(fmt_row([row[h] for h in headers]))

    print()
    for row in summary:
        if row["failed_cases"]:
            print(f"[{row['model']}] failed cases: {row['failed_cases']}")


def write_csv(summary: list[dict], out_path: Path):
    if not summary:
        return
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(summary[0].keys()))
        writer.writeheader()
        writer.writerows(summary)
    print(f"\nwrote per-model summary to {out_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results_csv", nargs="?", default=None,
                         help="path to a results.csv written by run_benchmark.py")
    parser.add_argument("--latest", action="store_true",
                         help="use the most recently written results/*/results.csv instead of a path")
    parser.add_argument("--results-dir", default=str(REPO_ROOT / "results"),
                         help="where to look for --latest (default: ./results)")
    parser.add_argument("--strict", action="store_true",
                         help="also require setup_ok and precondition_passed to be True")
    parser.add_argument("--exclude", default=None,
                         help="comma-separated case_id(s) to leave out of the summary, e.g. "
                              "--exclude q72392812 to exclude a case whose reference solution "
                              "is architecture-specific and couldn't be run on this machine")
    parser.add_argument("--out", default=None, help="also write the summary table to this CSV path")
    args = parser.parse_args()

    if args.latest:
        csv_path = find_latest_results_csv(Path(args.results_dir))
        print(f"(using latest: {csv_path})\n")
    elif args.results_csv:
        csv_path = Path(args.results_csv)
    else:
        parser.error("pass a results.csv path or use --latest")

    if not csv_path.exists():
        print(f"error: {csv_path} does not exist", file=sys.stderr)
        sys.exit(1)

    exclude_ids = {c.strip() for c in args.exclude.split(",")} if args.exclude else set()
    summary = summarize(csv_path, strict=args.strict, exclude_ids=exclude_ids)
    print_table(summary)

    if args.out:
        write_csv(summary, Path(args.out))


if __name__ == "__main__":
    main()
