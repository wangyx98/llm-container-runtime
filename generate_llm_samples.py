#!/usr/bin/env python3
"""
Calls an LLM API with each case's task.txt as the prompt, extracts the
shell command(s) it proposes, and writes them as samples into a JSON file
shaped exactly like samples/llm_outputs.json -- so they run through the
SAME five-stage harness (run_single_case.py / run_benchmark.py) as the
hand-written reference_solution / no_op_baseline / cheating_* samples.

Supports four provider backends, chosen with --provider:

  anthropic          Claude models via the Anthropic Messages API
                      (pip install anthropic; export ANTHROPIC_API_KEY=...)

  openai             GPT models via the OpenAI Chat Completions API
                      (pip install openai; export OPENAI_API_KEY=...)

  huggingface         Any open-weight model hosted on the Hugging Face
                      Inference API/Providers (e.g. Qwen2.5-Coder,
                      Llama-3.1, DeepSeek-Coder, ...)
                      (pip install huggingface_hub; export HF_TOKEN=...)

  openai_compatible   Anything that speaks the OpenAI chat-completions
                      wire format at a custom base URL: a self-hosted
                      vLLM/TGI/Ollama server, a HF Inference Endpoint,
                      OpenRouter, Together, Fireworks, etc.
                      (pip install openai; --base-url <url>,
                       optionally --api-key-env <ENV_VAR_NAME>)

Output goes to a SEPARATE file per run by default --
samples/generated/<provider>__<model>__<timestamp>.json -- so successive
runs (different models, or re-runs of the same model at a different
time) never clobber each other or the hand-written baseline samples used
to sanity-check the oracles themselves (samples/llm_outputs.json). Every
sample also carries "provider", "model", and "generated_at" fields, so a
run is self-describing even if a file gets renamed or merged later.
Pass --out explicitly to opt back into writing/merging into one shared
file instead (e.g. to accumulate several models into a single file
before running the harness once). See merge_samples.py to combine
several already-generated run files into one for a single
run_benchmark.py pass across multiple models.

Usage:
    # Claude
    pip install anthropic
    export ANTHROPIC_API_KEY=sk-ant-...
    python3 generate_llm_samples.py --provider anthropic \
        --model claude-sonnet-4-5 --all

    # ChatGPT / GPT
    pip install openai
    export OPENAI_API_KEY=sk-...
    python3 generate_llm_samples.py --provider openai \
        --model gpt-4o --all

    # An open-weight model on the Hugging Face Inference API
    pip install huggingface_hub
    export HF_TOKEN=hf_...
    python3 generate_llm_samples.py --provider huggingface \
        --model Qwen/Qwen2.5-Coder-32B-Instruct --all

    # Any OpenAI-compatible endpoint (self-hosted vLLM, HF Inference
    # Endpoint, OpenRouter, Together, ...)
    pip install openai
    export MY_ENDPOINT_KEY=...
    python3 generate_llm_samples.py --provider openai_compatible \
        --model meta-llama/Llama-3.1-70B-Instruct \
        --base-url https://your-endpoint.example.com/v1 \
        --api-key-env MY_ENDPOINT_KEY --all

Each run prints the exact output path it wrote to, e.g.:
    samples/generated/anthropic__claude-sonnet-4-5__2026-09-20_21-15-03.json

Then run that file's samples through the normal harness:
    python3 run_single_case.py q74317699 --model claude-sonnet-4-5 \
        --samples samples/generated/anthropic__claude-sonnet-4-5__2026-09-20_21-15-03.json

    python3 run_benchmark.py \
        --samples samples/generated/anthropic__claude-sonnet-4-5__2026-09-20_21-15-03.json

...and summarize pass@1 across all cases with:
    python3 compute_pass_at_1.py --latest
"""

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))

CASES_DIR = REPO_ROOT / "cases"
GENERATED_DIR = REPO_ROOT / "samples" / "generated"


def slugify_model(model: str) -> str:
    """Turn a model id like 'Qwen/Qwen2.5-Coder-32B-Instruct' or
    'gpt-4o' into something safe to put in a filename."""
    return re.sub(r"[^A-Za-z0-9._-]+", "_", model).strip("_")


def default_out_path(provider: str, model: str, run_timestamp: str) -> Path:
    """samples/generated/<provider>__<model-slug>__<timestamp>.json --
    one file per run, so nothing ever gets silently overwritten by a
    later run of a different (or the same) model."""
    return GENERATED_DIR / f"{provider}__{slugify_model(model)}__{run_timestamp}.json"

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


# ---------------------------------------------------------------------------
# provider backends -- each takes (model, prompt, args) and returns the raw
# text response. Imports are lazy so installing one SDK doesn't require the
# others.
# ---------------------------------------------------------------------------

def call_anthropic(model: str, prompt: str, args) -> str:
    """Anthropic Messages API. Reads ANTHROPIC_API_KEY from the environment."""
    import anthropic  # pip install anthropic

    client = anthropic.Anthropic()
    resp = client.messages.create(
        model=model,
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
    )
    return "".join(block.text for block in resp.content if block.type == "text")


def call_openai(model: str, prompt: str, args) -> str:
    """OpenAI Chat Completions API. Reads OPENAI_API_KEY from the environment."""
    from openai import OpenAI  # pip install openai

    client = OpenAI()
    resp = client.chat.completions.create(
        model=model,
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
    )
    return resp.choices[0].message.content or ""


def call_huggingface(model: str, prompt: str, args) -> str:
    """Hugging Face Inference API/Providers, via huggingface_hub's chat-completions
    interface (works for instruction-tuned open models regardless of which
    backend HF routes the request to). Reads HF_TOKEN from the environment
    unless --hf-token-env names a different variable."""
    import os

    from huggingface_hub import InferenceClient  # pip install huggingface_hub

    token_env = args.hf_token_env or "HF_TOKEN"
    token = os.environ.get(token_env)
    if not token:
        raise RuntimeError(f"environment variable {token_env} is not set")

    client = InferenceClient(model=model, token=token, provider=args.hf_provider or "auto")
    resp = client.chat_completion(
        messages=[{"role": "user", "content": prompt}],
        max_tokens=1024,
    )
    return resp.choices[0].message.content or ""


def call_openai_compatible(model: str, prompt: str, args) -> str:
    """Any server speaking the OpenAI chat-completions wire format at a
    custom base URL -- self-hosted vLLM/TGI/Ollama, a HF Inference
    Endpoint, OpenRouter, Together, Fireworks, etc."""
    import os

    from openai import OpenAI  # pip install openai

    if not args.base_url:
        raise RuntimeError("--base-url is required for --provider openai_compatible")

    key_env = args.api_key_env or "OPENAI_API_KEY"
    api_key = os.environ.get(key_env, "not-needed")  # some local servers don't check it

    client = OpenAI(base_url=args.base_url, api_key=api_key)
    resp = client.chat.completions.create(
        model=model,
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
    )
    return resp.choices[0].message.content or ""


PROVIDERS = {
    "anthropic": call_anthropic,
    "openai": call_openai,
    "huggingface": call_huggingface,
    "openai_compatible": call_openai_compatible,
}


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
    parser.add_argument("--provider", default="anthropic", choices=sorted(PROVIDERS.keys()),
                         help="which API backend to call (default: anthropic)")
    parser.add_argument("--model", required=True,
                         help="model name/id, e.g. claude-sonnet-4-5, gpt-4o, "
                              "Qwen/Qwen2.5-Coder-32B-Instruct")
    parser.add_argument("--case", default=None, help="run a single case_id, e.g. q74317699")
    parser.add_argument("--all", action="store_true", help="run every case found under cases/")
    parser.add_argument("--exclude", default=None,
                         help="comma-separated case_id(s) to skip when using --all, e.g. "
                              "--exclude q72392812 to skip a case whose reference solution "
                              "is architecture-specific (e.g. gVisor/runsc x86_64-only) and "
                              "can't run on this machine")
    parser.add_argument("--out", default=None,
                         help="output samples file. Default: a fresh, auto-named file per run "
                              "-- samples/generated/<provider>__<model>__<timestamp>.json -- so "
                              "different models and different runs are always kept as separate "
                              "backups. Pass this explicitly to merge into one shared file "
                              "instead (matching (case_id, model) entries are replaced, others "
                              "are kept).")
    parser.add_argument("--base-url", default=None,
                         help="(--provider openai_compatible only) base URL of the API server")
    parser.add_argument("--api-key-env", default=None,
                         help="(--provider openai_compatible only) env var holding the API key "
                              "(default: OPENAI_API_KEY)")
    parser.add_argument("--hf-provider", default=None,
                         help="(--provider huggingface only) which HF Inference Provider to "
                              "route to, e.g. together, fireworks-ai, hf-inference "
                              "(default: auto)")
    parser.add_argument("--hf-token-env", default=None,
                         help="(--provider huggingface only) env var holding the HF token "
                              "(default: HF_TOKEN)")
    parser.add_argument("--sleep", type=float, default=0.0,
                         help="seconds to sleep between calls, to stay under provider rate limits")
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

    exclude_ids = {c.strip() for c in args.exclude.split(",")} if args.exclude else set()
    if exclude_ids:
        skipped = [cid for _, cid in targets if cid in exclude_ids]
        targets = [(cat, cid) for cat, cid in targets if cid not in exclude_ids]
        unknown = exclude_ids - {cid for _, cid in all_cases}
        if unknown:
            print(f"warning: --exclude named case_id(s) not found under {CASES_DIR}: {sorted(unknown)}",
                  file=sys.stderr)
        if skipped:
            print(f"skipping {len(skipped)} excluded case(s): {skipped}\n")

    run_timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    out_path = Path(args.out) if args.out else default_out_path(args.provider, args.model, run_timestamp)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    samples = load_existing_samples(out_path)
    print(f"writing samples to: {out_path}\n")

    call_fn = PROVIDERS[args.provider]
    failures = []

    for i, (category, case_id) in enumerate(targets):
        task_path = CASES_DIR / category / case_id / "task.txt"
        task_text = task_path.read_text(encoding="utf-8")
        prompt = PROMPT_TEMPLATE.format(task=task_text)

        print(f"=== [{args.provider}:{args.model}] asking for a solution to {case_id} ({category}) ===")
        try:
            response_text = call_fn(args.model, prompt, args)
            code = extract_code(response_text)
            print(f"--- extracted code ---\n{code}\n----------------------\n")
        except Exception as exc:
            print(f"!!! call failed for {case_id}: {exc}\n", file=sys.stderr)
            failures.append((case_id, str(exc)))
            if i < len(targets) - 1 and args.sleep:
                time.sleep(args.sleep)
            continue

        # replace any existing sample for this (case_id, model) pair, else append
        samples = [
            s for s in samples
            if not (s["case_id"] == case_id and s.get("model") == args.model)
        ]
        samples.append({
            "case_id": case_id,
            "category": category,
            "model": args.model,
            "provider": args.provider,
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "code": code,
        })

        # write after every case, not just at the end, so a crash/rate-limit
        # partway through an --all run doesn't lose everything collected so far
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(samples, f, indent=2, ensure_ascii=False)

        if i < len(targets) - 1 and args.sleep:
            time.sleep(args.sleep)

    print(f"wrote {len(samples)} total sample(s) to {out_path}")
    if failures:
        print(f"\n{len(failures)} case(s) FAILED to generate a sample (left untouched in the output):")
        for case_id, err in failures:
            print(f"  - {case_id}: {err}")


if __name__ == "__main__":
    main()
