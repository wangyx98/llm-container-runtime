"""
One place that knows how samples are stored on disk, so run_benchmark.py,
run_single_case.py, merge_samples.py (and anything new) read them the same way.

Two kinds of samples exist, and they live apart:

  fixtures   hand-written samples that exist to test the ORACLES themselves
             (reference_solution, no_op_baseline, naive_*, cheat_*, alt_valid_*).
             One JSON file per case, grouped by taxonomy category:
                 samples/fixtures/<category>/<case_id>.json
             Each file is a JSON list of {case_id, category, model, code}.

  generated  real LLM outputs written by generate_llm_samples.py:
                 samples/generated/<provider>__<model>__<timestamp>.json
             (and anything merge_samples.py wrote). Flat JSON lists of the same shape.

A "source" handed to load_samples() may be:
  - a JSON file holding a list of samples (the old samples/llm_outputs.json
    still works, and so does every file under samples/generated/),
  - a directory: every *.json below it is read, in sorted path order.

Every loaded sample is the stored dict plus two private keys that say where it
came from: "_kind" ("fixture" or "model") and "_source" (the file). run_benchmark.py
moves them into the results row and removes them before the sample reaches a
test suite, so suites see exactly what is stored.
"""

import fnmatch
import json
import sys
from pathlib import Path
from typing import Iterable

REPO_ROOT = Path(__file__).resolve().parents[2]
SAMPLES_DIR = REPO_ROOT / "samples"
FIXTURES_DIR = SAMPLES_DIR / "fixtures"
GENERATED_DIR = SAMPLES_DIR / "generated"
LEGACY_FIXTURES_FILE = SAMPLES_DIR / "llm_outputs.json"

KIND_FIXTURE = "fixture"
KIND_MODEL = "model"


class SampleLoadError(Exception):
    """Raised with ONE message that lists every problem found, so a broken
    file is reported together with all the others instead of one per run."""


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def kind_of(path: Path) -> str:
    """Fixtures = anything under samples/fixtures/ and the legacy single file
    samples/llm_outputs.json. Everything else is treated as real model output."""
    if _is_within(path, FIXTURES_DIR) or path.resolve() == LEGACY_FIXTURES_FILE.resolve():
        return KIND_FIXTURE
    return KIND_MODEL


def expand_sources(sources: Iterable) -> list[Path]:
    """Files stay as they are; a directory becomes every *.json under it, sorted."""
    files: list[Path] = []
    for src in sources:
        p = Path(src)
        if not p.exists():
            raise SampleLoadError(f"samples source not found: {p}")
        if p.is_dir():
            files.extend(sorted(p.rglob("*.json")))
        else:
            files.append(p)
    return files


def default_source(cfg: dict) -> Path:
    """Where `python3 run_benchmark.py` reads from when nothing else is named:
    config key `samples_path` (a file or a directory), else the old
    `samples_file` key, else samples/fixtures."""
    value = cfg.get("samples_path") or cfg.get("samples_file")
    if not value:
        return FIXTURES_DIR
    p = Path(value)
    return p if p.is_absolute() else REPO_ROOT / p


def _check_fixture_path(path: Path, entry: dict, problems: list):
    """samples/fixtures/<category>/<case_id>.json: the path and the sample must agree."""
    rel = path.resolve().relative_to(FIXTURES_DIR.resolve())
    if len(rel.parts) != 2:
        problems.append(f"{path}: a fixtures file must be samples/fixtures/<category>/<case_id>.json")
        return
    category, case_id = rel.parts[0], rel.parts[1][: -len(".json")]
    if entry.get("category") != category:
        problems.append(f"{path}: sample {entry.get('model')!r} says category {entry.get('category')!r}, "
                        f"but the file is under {category!r}")
    if entry.get("case_id") != case_id:
        problems.append(f"{path}: sample {entry.get('model')!r} says case_id {entry.get('case_id')!r}, "
                        f"but the file is named {case_id!r}")


def load_samples(sources: Iterable, only_cases: set | None = None) -> list[dict]:
    """Read every sample from the given files/directories.

    only_cases: when given, fixtures files of other cases are not even opened
                (their file name is the case id), so one broken file cannot
                stop a run that never needed it.

    Duplicates: two fixtures with the same (case_id, model) are an error. For
    real model output a later file wins (files are read in sorted path order,
    and the timestamp is part of the file name), with a note on stderr -- the
    same rule merge_samples.py has always used.
    """
    problems: list[str] = []
    merged: dict[tuple, dict] = {}
    order: list[tuple] = []

    for path in expand_sources(sources):
        kind = kind_of(path)
        if only_cases is not None and kind == KIND_FIXTURE and _is_within(path, FIXTURES_DIR) \
                and path.stem not in only_cases:
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError) as exc:
            problems.append(f"{path}: cannot read as JSON: {exc}")
            continue
        if not isinstance(data, list) or not all(isinstance(s, dict) for s in data):
            problems.append(f"{path}: expected a JSON list of sample objects")
            continue

        for entry in data:
            if not entry.get("case_id") or "model" not in entry:
                problems.append(f"{path}: a sample without case_id/model: {json.dumps(entry)[:100]}")
                continue
            if kind == KIND_FIXTURE and _is_within(path, FIXTURES_DIR):
                _check_fixture_path(path, entry, problems)
            if only_cases is not None and entry["case_id"] not in only_cases:
                continue
            sample = dict(entry)
            sample["_kind"] = kind
            sample["_source"] = str(path)
            key = (sample["case_id"], sample.get("model"))
            if key in merged:
                if kind == KIND_FIXTURE and merged[key]["_kind"] == KIND_FIXTURE:
                    problems.append(f"duplicate fixture for case_id={key[0]!r} model={key[1]!r} "
                                    f"({merged[key]['_source']} and {path})")
                    continue
                print(f"note: {path.name} overrides an earlier sample for "
                      f"case_id={key[0]!r} model={key[1]!r}", file=sys.stderr)
            else:
                order.append(key)
            merged[key] = sample

    if problems:
        raise SampleLoadError("problems in the samples files:\n  - " + "\n  - ".join(problems))
    return [merged[k] for k in order]


def _split(value) -> set | None:
    if not value:
        return None
    items = {v.strip() for v in value.split(",") if v.strip()} if isinstance(value, str) else set(value)
    return items or None


def filter_samples(samples: list[dict], cases=None, categories=None, models=None, exclude=None) -> list[dict]:
    """cases / categories / exclude: comma-separated ids (or a set). models: comma-separated
    names or shell-style patterns, e.g. "reference_solution,naive_*"."""
    cases, categories, exclude = _split(cases), _split(categories), _split(exclude)
    patterns = _split(models)
    out = []
    for s in samples:
        if cases and s["case_id"] not in cases:
            continue
        if categories and s.get("category") not in categories:
            continue
        if exclude and s["case_id"] in exclude:
            continue
        if patterns and not any(fnmatch.fnmatchcase(str(s.get("model")), pat) for pat in patterns):
            continue
        out.append(s)
    return out


def strip_private(sample: dict) -> dict:
    """The sample exactly as stored (without the _kind/_source bookkeeping keys)."""
    return {k: v for k, v in sample.items() if not k.startswith("_")}
