#!/usr/bin/env python3
"""
Summarize several results.csv files (each written by run_benchmark.py) into a pass@10
table: one row per model, showing the share of cases that at least one of 10 independent
runs solved, i.e. where the postcondition oracle passed. pass@1 is printed next to it.

This is the multi-run counterpart of compute_pass_at_1.py. A "run" is one ordinary pass of the
existing workflow, repeated for the same model (nothing in generate_llm_samples.py or
run_benchmark.py changes):

    python3 generate_llm_samples.py --provider <provider> --model <model> --all
    python3 run_benchmark.py --samples samples/generated/<the file it just wrote>

Each run writes its own results/<timestamp>/results.csv. Every file handed to this script is
one more independent attempt: run 2 never sees run 1's output. (Do not use
`run_benchmark.py --generated` for this: it keeps only the latest sample of a model per case,
which would collapse the runs into one.)

For one model and one case, n runs give n samples of which c passed the oracle. With
k = 10, the unbiased estimator of Chen et al. (2021, "Evaluating Large Language Models
Trained on Code") is

    pass@10(case) = 1 - C(n - c, 10) / C(n, 10)

and pass@10(model) is the mean over its cases. With exactly 10 runs (n = 10) this is simply

    pass@10(model) = (# cases solved by at least one run) / (# cases)

With more than 10 runs the estimator averages over all choices of 10 runs, which has the same
expectation with less variance than taking the first 10.

pass@10 is oracle-selected coverage: the oracle picks the winning run, so it is an upper bound
on what a system without an oracle could achieve. pass@1 is the single-answer figure. The
runs only differ if the model samples randomly; if every run returns the same answer,
pass@10 equals pass@1.

A case that has fewer than 10 samples (for example one generation call failed in some run)
cannot count towards pass@10. It is left out of that column, and the cell is marked with *
when this happens.

results.csv rows with sample_kind == "fixture" (the hand-written samples that test the oracles)
are not models and are skipped, as in compute_pass_at_1.py. Rows from older results.csv files
without that column are all treated as model rows.

The --strict flag also requires setup_ok and precondition_passed to be True (excludes cases
where the harness itself misbehaved rather than the model's solution being wrong).

Usage:
    python3 compute_pass_at_10.py results/<run1>/results.csv results/<run2>/results.csv ...
    python3 compute_pass_at_10.py results/*/results.csv --strict
    python3 compute_pass_at_10.py results/<run1>/results.csv ... --out summary.csv

    # the 10 most recently written results.csv files, without typing the paths
    # (this also picks up runs of other models, so use it when only one model was run)
    python3 compute_pass_at_10.py --latest 10

    # one row per (model, category) instead of one per model
    python3 compute_pass_at_10.py results/<run1>/results.csv ... --by-category
"""

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent

K = 10


def _to_bool(value) -> bool:
    """results.csv stores Python bool reprs as the strings 'True'/'False'
    (DictWriter just calls str() on whatever run_benchmark.py put there)."""
    return str(value).strip().lower() == "true"


def _is_fixture(row) -> bool:
    return (row.get("sample_kind") or "").strip().lower() == "fixture"


def pass_at_k(n: int, c: int, k: int) -> float:
    """Unbiased pass@k for one case: n samples, c of them passed the oracle.
    1 - C(n-c, k) / C(n, k), evaluated as 1 - prod_{i=n-c+1..n} (1 - k/i) so that no huge
    binomials are formed."""
    if not 1 <= k <= n:
        raise ValueError(f"need 1 <= k <= n, got k={k}, n={n}")
    if not 0 <= c <= n:
        raise ValueError(f"need 0 <= c <= n, got c={c}, n={n}")
    if n - c < k:          # fewer than k failures: every choice of k runs contains a pass
        return 1.0
    miss = 1.0
    for i in range(n - c + 1, n + 1):
        miss *= 1.0 - k / i
    return 1.0 - miss


def find_latest_results_csvs(results_dir: Path, count: int) -> list[Path]:
    candidates = sorted(results_dir.glob("*/results.csv"), key=lambda p: p.stat().st_mtime)
    if len(candidates) < count:
        raise FileNotFoundError(f"asked for the {count} latest results.csv files, but only "
                                f"{len(candidates)} found under {results_dir}/*/results.csv")
    return candidates[-count:]


def load_rows(csv_path: Path) -> list[dict]:
    with open(csv_path, "r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def collect(csv_paths: list[Path], strict: bool, exclude_ids: set[str] | None = None):
    """-> ({model: {case_id: [n_samples, n_passed]}}, {case_id: category}).
    Every real-model row of every file is one sample."""
    exclude_ids = exclude_ids or set()
    counts: dict[str, dict[str, list[int]]] = defaultdict(dict)
    category: dict[str, str] = {}
    skipped_fixtures = 0
    skipped_cases: set[str] = set()
    for path in csv_paths:
        for row in load_rows(path):
            if _is_fixture(row):
                skipped_fixtures += 1
                continue
            case_id = row.get("case_id")
            if case_id in exclude_ids:
                skipped_cases.add(case_id)
                continue
            passed = _to_bool(row.get("oracle_passed"))
            if strict:
                passed = passed and _to_bool(row.get("setup_ok")) and _to_bool(row.get("precondition_passed"))
            nc = counts[row.get("model") or "unknown"].setdefault(case_id, [0, 0])
            nc[0] += 1
            nc[1] += int(passed)
            category[case_id] = row.get("category") or "unknown"
    if skipped_fixtures:
        print(f"(leaving out {skipped_fixtures} hand-written fixture row(s); they are not models)\n")
    if skipped_cases:
        print(f"excluding case(s): {sorted(skipped_cases)}\n")
    return counts, category


def score(per_case: dict[str, list[int]]) -> dict:
    """pass@1 over every case, pass@K over the cases that have at least K samples."""
    ns = [n for n, _ in per_case.values()]
    p1 = [pass_at_k(n, c, 1) for n, c in per_case.values()]
    pk_cases = {cid: nc for cid, nc in per_case.items() if nc[0] >= K}
    pk = [pass_at_k(n, c, K) for n, c in pk_cases.values()]
    return {
        "cases": len(per_case),
        "runs_min": min(ns),
        "runs_max": max(ns),
        "pass@1": sum(p1) / len(p1),
        f"pass@{K}": (sum(pk) / len(pk)) if pk else None,
        f"cases_used@{K}": len(pk),
        "unsolved_cases": sorted(cid for cid, (n, c) in pk_cases.items() if c == 0),
    }


def summarize(counts, category, by_category: bool) -> list[dict]:
    summary = []
    for model in sorted(counts):
        if not by_category:
            summary.append({"model": model, **score(counts[model])})
            continue
        groups: dict[str, dict[str, list[int]]] = defaultdict(dict)
        for case_id, nc in counts[model].items():
            groups[category[case_id]][case_id] = nc
        for cat in sorted(groups):
            summary.append({"model": model, "category": cat, **score(groups[cat])})
    return summary


def _pct(row: dict, key: str) -> str:
    value = row[key]
    if value is None:
        return "n/a"
    marker = "*" if key == f"pass@{K}" and row[f"cases_used@{K}"] < row["cases"] else ""
    return f"{value * 100:.1f}%{marker}"


def print_table(summary: list[dict], by_category: bool):
    if not summary:
        print("no rows to summarize")
        return

    lead = ["model"] + (["category"] if by_category else [])
    headers = lead + ["cases", "runs", "pass@1_pct", f"pass@{K}_pct"]
    table = []
    for row in summary:
        runs = str(row["runs_min"]) if row["runs_min"] == row["runs_max"] else f"{row['runs_min']}-{row['runs_max']}"
        table.append([str(row[c]) for c in lead]
                     + [str(row["cases"]), runs, _pct(row, "pass@1"), _pct(row, f"pass@{K}")])
    widths = [max(len(h), max(len(r[i]) for r in table)) for i, h in enumerate(headers)]

    def fmt_row(values):
        return "  ".join(str(v).ljust(w) for v, w in zip(values, widths))

    print(fmt_row(headers))
    print(fmt_row(["-" * w for w in widths]))
    for r in table:
        print(fmt_row(r))

    print()
    for row in summary:
        if row["unsolved_cases"]:
            who = f"{row['model']}/{row['category']}" if by_category else row["model"]
            print(f"[{who}] not solved in any run: {';'.join(row['unsolved_cases'])}")

    if any(row[f"cases_used@{K}"] == 0 for row in summary):
        print(f"\nn/a = no case has {K} samples yet: run the benchmark at least {K} times for that model")
    if any(0 < row[f"cases_used@{K}"] < row["cases"] for row in summary):
        print(f"\n* computed only over the cases that have at least {K} samples (cases_used@{K} in --out); "
              f"do not compare it with a column computed over all cases")
    print(f"\npass@{K} = P(at least one of {K} runs passes the oracle), oracle-selected coverage (an upper bound); "
          f"pass@1 is the single-answer figure")


def write_csv(summary: list[dict], out_path: Path):
    if not summary:
        return
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        fieldnames = list(summary[0].keys())
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in summary:
            writer.writerow({
                key: (";".join(value) if key == "unsolved_cases"
                      else "" if value is None
                      else f"{value:.4f}" if isinstance(value, float) else value)
                for key, value in row.items()
            })
    print(f"\nwrote per-model summary to {out_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results_csv", nargs="*",
                        help="the results.csv files of the independent runs (one run_benchmark.py run each)")
    parser.add_argument("--latest", type=int, default=None, metavar="N",
                        help="use the N most recently written results/*/results.csv instead of listing paths")
    parser.add_argument("--results-dir", default=str(REPO_ROOT / "results"),
                        help="where to look for --latest (default: ./results)")
    parser.add_argument("--strict", action="store_true",
                        help="also require setup_ok and precondition_passed to be True")
    parser.add_argument("--exclude", default=None,
                        help="comma-separated case_id(s) to leave out of the summary, e.g. "
                             "--exclude q72392812 to exclude a case whose reference solution "
                             "is architecture-specific and couldn't be run on this machine")
    parser.add_argument("--by-category", action="store_true",
                        help="one row per (model, category) instead of one row per model")
    parser.add_argument("--out", default=None, help="also write the summary table to this CSV path")
    args = parser.parse_args()

    if args.latest:
        csv_paths = find_latest_results_csvs(Path(args.results_dir), args.latest)
    elif args.results_csv:
        csv_paths = [Path(p) for p in args.results_csv]
    else:
        parser.error("pass the results.csv files of the runs or use --latest N")

    unique: dict[Path, Path] = {}
    for path in csv_paths:
        if not path.exists():
            print(f"error: {path} does not exist", file=sys.stderr)
            sys.exit(1)
        if path.resolve() in unique:
            print(f"warning: {path} was listed twice; counting it once (a run must not be counted twice)",
                  file=sys.stderr)
        unique[path.resolve()] = path
    csv_paths = list(unique.values())

    print(f"using {len(csv_paths)} run(s):")
    for path in csv_paths:
        print(f"  {path}")
    print()

    exclude_ids = {c.strip() for c in args.exclude.split(",")} if args.exclude else set()
    counts, category = collect(csv_paths, strict=args.strict, exclude_ids=exclude_ids)
    if not counts:
        print("no real-model rows to score in these results.csv files. Run `python3 run_benchmark.py "
              "--samples <file from generate_llm_samples.py>` first (fixtures are not models).")
        sys.exit(1)

    summary = summarize(counts, category, by_category=args.by_category)
    print_table(summary, by_category=args.by_category)

    if args.out:
        write_csv(summary, Path(args.out))


if __name__ == "__main__":
    main()
