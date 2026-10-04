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

results.csv has a `sample_kind` column (written by run_benchmark.py):
"model" for real LLM outputs (samples/generated/...) and "fixture" for the
hand-written samples that test the oracles (samples/fixtures/...). The pass@1
table covers real models only -- a fixture such as reference_solution is not a
model and would otherwise show up in it as a model with 100%. Rows from older
results.csv files without that column are all treated as model rows.

--fixtures does the opposite job: it checks the HAND-WRITTEN samples of a run
against what their names promise (reference_solution and alt_valid_* must pass
the oracle; no_op_baseline, naive_*, cheat*, wrong_*, ... must not), prints one
line per role and lists every mismatch. That is the "are the oracles still
correct" check to run after changing a case, the harness, or the environment.

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

    # real models only (default), or everything in the file
    python3 compute_pass_at_1.py --latest --include-fixtures

    # check the hand-written samples of the latest run against their names
    python3 compute_pass_at_1.py --latest --fixtures
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


def _is_fixture(row) -> bool:
    return (row.get("sample_kind") or "").strip().lower() == "fixture"


def expected_pass(model: str) -> bool:
    """What a hand-written sample's name promises: the reference solution and the
    alt_valid_* samples (another correct route) must pass the oracle; everything
    else (no_op_baseline, naive_*, cheat_*, cheating_*, wrong_*, partial_*, ...) must not."""
    return model == "reference_solution" or model.startswith("alt_valid")


def role_of(model: str) -> str:
    if model == "reference_solution":
        return "reference_solution"
    if model.startswith("alt_valid"):
        return "alt_valid_* (another correct route)"
    if model == "no_op_baseline":
        return "no_op_baseline"
    return "naive_/cheat_/wrong_... (must be rejected)"


def find_latest_results_csv(results_dir: Path) -> Path:
    candidates = sorted(results_dir.glob("*/results.csv"), key=lambda p: p.stat().st_mtime)
    if not candidates:
        raise FileNotFoundError(f"no results.csv found under {results_dir}/*/results.csv")
    return candidates[-1]


def load_rows(csv_path: Path) -> list[dict]:
    with open(csv_path, "r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def summarize(csv_path: Path, strict: bool, exclude_ids: set[str] | None = None,
              include_fixtures: bool = False) -> list[dict]:
    rows = load_rows(csv_path)
    if not include_fixtures:
        fixtures = [r for r in rows if _is_fixture(r)]
        if fixtures:
            print(f"(leaving out {len(fixtures)} hand-written fixture row(s); they are not models. "
                  f"Use --include-fixtures to count them, or --fixtures to check them)\n")
        rows = [r for r in rows if not _is_fixture(r)]

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


def check_fixtures(csv_path: Path, strict: bool, exclude_ids: set[str] | None = None) -> bool:
    """Compare every hand-written sample's verdict with what its name promises.
    Returns True when all agree and none had a harness problem."""
    rows = load_rows(csv_path)
    has_kind_column = bool(rows) and "sample_kind" in rows[0]
    fixtures = [r for r in rows if _is_fixture(r)] if has_kind_column else rows
    if not has_kind_column:
        print("(this results.csv has no sample_kind column, so every row is checked as if it were a fixture)\n")
    exclude_ids = exclude_ids or set()
    fixtures = [r for r in fixtures if r.get("case_id") not in exclude_ids]
    if not fixtures:
        print("no fixture rows in this results.csv (run `python3 run_benchmark.py --fixtures` first)")
        return False

    roles: dict[str, dict] = {}
    mismatches, harness = [], []
    for r in fixtures:
        model = r.get("model") or "unknown"
        role = roles.setdefault(role_of(model), {"samples": 0, "passed": 0, "expected_pass": expected_pass(model)})
        role["samples"] += 1
        if not _to_bool(r.get("setup_ok")) or not _to_bool(r.get("precondition_passed")):
            harness.append(r)          # the lifecycle never reached a verdict
            continue
        passed = _to_bool(r.get("oracle_passed"))
        role["passed"] += int(passed)
        if passed != expected_pass(model):
            mismatches.append((r, passed))

    headers = ["role", "samples", "passed oracle", "must pass?"]
    table = [[name, str(v["samples"]), str(v["passed"]), "yes" if v["expected_pass"] else "no"]
             for name, v in sorted(roles.items())]
    widths = [max(len(h), max(len(row[i]) for row in table)) for i, h in enumerate(headers)]
    fmt = lambda vals: "  ".join(v.ljust(w) for v, w in zip(vals, widths))  # noqa: E731
    print(fmt(headers))
    print(fmt(["-" * w for w in widths]))
    for row in table:
        print(fmt(row))

    ok = not mismatches and not harness
    print()
    for r, passed in mismatches:
        tail = (r.get("error_message") or "").strip().splitlines()[-1:] or [""]
        print(f"MISMATCH [{r.get('case_id')}] {r.get('model')}: oracle says "
              f"{'PASS' if passed else 'FAIL'}, its name promises {'PASS' if expected_pass(r.get('model') or '') else 'FAIL'}"
              f"   ({tail[0][:140]})")
    for r in harness:
        print(f"NO VERDICT [{r.get('case_id')}] {r.get('model')}: setup or precondition did not succeed "
              f"({(r.get('error_message') or '')[:140]})")
    if ok:
        print(f"all {len(fixtures)} fixture sample(s) behave as their names promise")
    else:
        print(f"\n{len(mismatches)} mismatch(es), {len(harness)} without a verdict, out of {len(fixtures)} fixture sample(s)")
    return ok


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
    parser.add_argument("--include-fixtures", action="store_true",
                         help="also count the hand-written fixture rows as if they were models "
                              "(the old behavior; by default only real models are scored)")
    parser.add_argument("--fixtures", action="store_true",
                         help="instead of pass@1, check the hand-written fixture rows against what "
                              "their names promise (reference_solution/alt_valid_* pass, the rest fail); "
                              "exit code 1 if anything is off")
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

    if args.fixtures:
        sys.exit(0 if check_fixtures(csv_path, strict=args.strict, exclude_ids=exclude_ids) else 1)

    summary = summarize(csv_path, strict=args.strict, exclude_ids=exclude_ids,
                        include_fixtures=args.include_fixtures)
    if not summary:
        print("no real-model rows to score in this results.csv. If it holds hand-written fixtures, "
              "use --fixtures to check them, or --include-fixtures to score them like models; "
              "to score real models run `python3 run_benchmark.py --generated` first.")
    else:
        print_table(summary)

    if args.out:
        write_csv(summary, Path(args.out))


if __name__ == "__main__":
    main()
