#!/usr/bin/env python3
"""
Calls an LLM API with each case's task.txt as the prompt, extracts the
shell command(s) it proposes, and writes them as samples into a JSON file
shaped exactly like samples/llm_outputs.json -- so they run through the
SAME five-stage harness (run_single_case.py / run_benchmark.py) as the
hand-written reference_solution / no_op_baseline / cheating_* samples.

This is the missing "ask a real LLM for its answer" step: everything in
samples/llm_outputs.json today was hand-written by a human, not produced
by calling a model.

Output goes to a SEPARATE file (samples/llm_generated_outputs.json by
default) so real model answers never overwrite the hand-written baseline
samples used to sanity-check the oracles themselves.

Usage:
    pip install anthropic
    export ANTHROPIC_API_KEY=sk-ant-...

    # one case, one model
    python3 generate_llm_samples.py --model claude-sonnet-4-5 --case q74317699

    # every case that has a task.txt under cases/
    python3 generate_llm_samples.py --model claude-sonnet-4-5 --all

Then run it through the normal harness:
    python3 run_single_case.py q74317699 --model claude-sonnet-4-5 \
        --samples samples/llm_generated_outputs.json

    python3 run_benchmark.py --samples samples/llm_generated_outputs.json
"""

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))

CASES_DIR = REPO_ROOT / "cases"
DEFAULT_OUTPUT = REPO_ROOT / "samples" / "llm_generated_outputs.json"

PROMPT_TEMPLATE = """You are given a real-world container runtime problem reported \
on Stack Overflow. Read the task below and respond with ONLY the shell \
command(s) needed to solve it, inside a single ```bash code block. Do not \
explain your reasoning and do not add any commentary outside the code block.

--- TASK ---
{task}
--- END TASK ---
"""


def find_all_case_ids():
    """Discover (category, case_id) pairs from cases/<category>/<case_id>/task.txt."""
    result = []
    for task_file in sorted(CASES_DIR.glob("*/*/task.txt")):
        category = task_file.parent.parent.name
        case_id = task_file.parent.name
        result.append((category, case_id))
    return result


def call_anthropic(model: str, prompt: str) -> str:
    """Call the Anthropic Messages API. Reads ANTHROPIC_API_KEY from the environment."""
    import anthropic  # pip install anthropic

    client = anthropic.Anthropic()
    resp = client.messages.create(
        model=model,
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
    )
    return "".join(block.text for block in resp.content if block.type == "text")


def extract_code(response_text: str) -> str:
    """Pull the first ```bash/```sh/``` fenced block out of the response.
    Falls back to the raw response text if no fenced block is found."""
    m = re.search(r"```(?:bash|sh)?\s*\n(.*?)```", response_text, re.DOTALL)
    if m:
        return m.group(1).strip()
    return response_text.strip()


def load_existing_samples(path: Path) -> list:
    if path.exists():
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True, help="model name, e.g. claude-sonnet-4-5")
    parser.add_argument("--case", default=None, help="run a single case_id, e.g. q74317699")
    parser.add_argument("--all", action="store_true", help="run every case found under cases/")
    parser.add_argument("--out", default=str(DEFAULT_OUTPUT), help="output samples file")
    args = parser.parse_args()

    if not args.case and not args.all:
        parser.error("pass --case <id> or --all")

    all_cases = find_all_case_ids()
    if args.case:
        targets = [(cat, cid) for cat, cid in all_cases if cid == args.case]
        if not targets:
            parser.error(f"case_id '{args.case}' not found under {CASES_DIR}")
    else:
        targets = all_cases

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    samples = load_existing_samples(out_path)

    for category, case_id in targets:
        task_path = CASES_DIR / category / case_id / "task.txt"
        task_text = task_path.read_text(encoding="utf-8")
        prompt = PROMPT_TEMPLATE.format(task=task_text)

        print(f"=== asking '{args.model}' to solve {case_id} ({category}) ===")
        response_text = call_anthropic(args.model, prompt)
        code = extract_code(response_text)
        print(f"--- extracted code ---\n{code}\n----------------------\n")

        # replace any existing sample for this (case_id, model) pair, else append
        samples = [
            s for s in samples
            if not (s["case_id"] == case_id and s.get("model") == args.model)
        ]
        samples.append({
            "case_id": case_id,
            "category": category,
            "model": args.model,
            "code": code,
        })

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(samples, f, indent=2, ensure_ascii=False)
    print(f"wrote {len(samples)} total sample(s) to {out_path}")


if __name__ == "__main__":
    main()
