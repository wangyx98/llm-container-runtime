# LLM Container Runtime Benchmark

Executable benchmark suite for evaluating LLM-generated shell solutions
against real container runtime environments (containerd, and future
runtimes), built from Stack Overflow questions with reproducible
setup/oracle/cleanup lifecycles.

## Test case lifecycle

Every case follows the same fixed lifecycle:

    reset → setup → precondition oracle → LLM solution → postcondition oracle → cleanup

- **setup** builds a clean, deterministic starting environment
- **precondition** proves the target state does NOT already exist
  (so a PASS later can't be a false positive)
- the LLM-generated solution is executed as-is, unmodified
- **oracle** verifies the postcondition (existence, content correctness,
  and — critically — that the environment wasn't cheated, e.g. a
  container/task getting deleted and recreated instead of mutated in place)
- **cleanup** tears everything down so the next sample starts from the same S0

## Taxonomy

Cases are organized under `cases/<category>/<case_id>/` and
`src/test_suites/<category>/<case_id>.py` by the kind of runtime problem
they exercise:

| # | Category (full name) | Directory keyword |
|---|---|---|
| 1 | Runtime Compatibility | `compatibility` |
| 2 | Configuration Management | `configuration` |
| 3 | Filesystem, Mount & Storage | `filesystem` |
| 4 | Identity, Privilege & Isolation | `isolation` |
| 5 | Networking & Connectivity | `networking` |
| 6 | Diagnostics & Observability | `diagnostics` |

A case is placed in whichever category best matches what it's actually
testing — e.g. SO-75798292 (copying a host file into a running
containerd container's filesystem) lives under `filesystem`, not
`compatibility`, even though it involves a running container, because the thing being exercised is a filesystem/mount operation, not the
container's lifecycle itself.

See [`SO_questions_tasks_mapping.csv`](./SO_questions_tasks_mapping.csv)
for the updated full list of screened Stack Overflow questions and their 6 updated tasks taxonomy mapping.

## Structure

```
llm-container-runtime-benchmark/
├── README.md
├── SO_questions_tasks_mapping.csv
├── conf/
│   └── config.yaml              # timeout, samples_file, results_dir — single source of config
│
├── cases/
│   ├── compatibility/
│   ├── configuration/
│   │  test kit
│   │       ├── setup.sh
│   │       ├── precondition.sh
│   │       ├── reference_solution.sh
│   │       ├── oracle.sh
│   │       ├── cleanup.sh
│   │       └── task.txt
│   ├── filesystem/
│   ├── isolation/
│   ├── networking/
│   └── diagnostics/
│
├── src/
│   ├── cfg_reader/
│   │   └── primary.py           # load(path) -> dict, reads conf/config.yaml
│   ├── utils/
│   │   └── shell.py             # subprocess wrapper shared by all cases
│   └── test_suites/
│       ├── compatibility/
│       ├── configuration/
│       │   └── q61058619.py     # run_tests(sample, cfg) -> (cases, error_message)
│       ├── filesystem/
│       │   └── q75798292.py     # run_tests(sample, cfg) -> (cases, error_message)
│       │                        # orchestrates the bash scripts above,
│       │                        # does NOT reimplement test logic in Python
│       ├── isolation/
│       │   └── q70714501.py
│       ├── networking/
│       └── diagnostics/
│
├── samples/
│   ├── llm_outputs.json          # hand-written reference_solution/no_op_baseline/cheating_*
│   └── generated/                # real LLM outputs, one auto-named file per run (see below):
│       └── <provider>__<model>__<timestamp>.json
│
├── results/
│   └── <timestamp>/results.csv  # run_benchmark.py writes here, one folder per run
│
├── requirements.txt
├── generate_llm_samples.py       # calls a real LLM API (Claude/GPT/HF/OpenAI-compatible) on
│                                  # each case's task.txt, writes samples/generated/...
├── merge_samples.py              # combine several samples/generated/*.json files into one,
│                                  # for a single run_benchmark.py pass across multiple models
├── compute_pass_at_1.py          # aggregate a results.csv into a per-model pass@1 table
├── run_benchmark.py              # top-level driver: loads config + samples, calls the
│                                  # right test_suites module, writes timestamped results
└── run_single_case.py            # run the full 5-stage lifecycle for ONE case only,
                                   # without touching the others (see "Running" below)
```

Empty category folders under `cases/` (nothing to test there yet) keep a
`.gitkeep` placeholder so the taxonomy is visible in the repo even before
every category has a case in it.

## Running

### All cases / batch mode

```bash
pip install -r requirements.txt
python3 run_benchmark.py
```

By default this reads `conf/config.yaml` and `samples/llm_outputs.json`.
Override either on the command line:

```bash
python3 run_benchmark.py --config conf/config.yaml --samples samples/llm_outputs.json
```

For every sample, it will:
1. `cleanup.sh` (reset environment)
2. `setup.sh`
3. `precondition.sh` (abort this sample if precondition itself fails)
4. run the sample's `code` as a shell snippet
5. `oracle.sh`
6. `cleanup.sh` again

Results are written to a **timestamped** folder so previous runs are never
overwritten: `results/2026-09-08_00-41-12/results.csv`, with columns like
`case_id, category, model, setup_ok, precondition_passed,
solution_executed, oracle_passed, error_message`.

### A single case only

`run_single_case.py` runs the exact same 5-stage lifecycle as
`run_benchmark.py`, but for just one case, without editing
`samples/llm_outputs.json` and without manually running the 4 bash
scripts by hand. It auto-detects which taxonomy category a case belongs
to by scanning `src/test_suites/*/<case_id>.py`, so you never need to
type the category yourself.

```bash
# run the case's reference_solution sample (default if present)
python3 run_single_case.py q61058619

# run a specific named sample already defined in samples/llm_outputs.json
python3 run_single_case.py q61058619 --model cheating_allow_all_profile
python3 run_single_case.py q70714501 --model no_op_baseline

# run arbitrary ad-hoc shell code without touching samples/llm_outputs.json
python3 run_single_case.py q75798292 --code "echo hello world"
```

It prints the same structured result dict `run_tests()` produces
(`setup_ok`, `precondition_passed`, `oracle_passed`, etc.), a final
PASS/FAIL line, and exits with code `0` on PASS / `1` on FAIL so it can
be used in shell scripts (`if python3 run_single_case.py q61058619; then ...`).
It does not write anything to `results/` — that's what `run_benchmark.py`
is for when you want a persisted, aggregated CSV across many samples.

## Adding a new case

1. Decide which of the 6 taxonomy categories the case belongs to (by what
   it actually exercises, not just "it involves a container").
2. Add `cases/<category>/<case_id>/` with the 4 scripts + `task.txt`.
3. Add `src/test_suites/<category>/<case_id>.py` implementing
   `run_tests(sample, cfg) -> (cases, error_message)` — copy an existing
   one (e.g. `q75798292.py`) and change the script names / `CASE_DIR`.
4. Add samples for it to `samples/llm_outputs.json` with
   `"category": "<category>"`.
5. Smoke-test just this case with `python3 run_single_case.py <case_id>`
   before running the full batch — much faster than waiting for
   `run_benchmark.py` to cycle through every other case too.

`run_benchmark.py` never needs to change — it dispatches purely by the
`category` + `case_id` fields on each sample.

## Dynamically testing an LLM's problem-solving ability

The harness evaluates solutions by **executing them and checking real
system state** (`oracle.sh`), not by diffing text against
`reference_solution.sh`. `reference_solution.sh` is just one hand-written
way to pass — an LLM can take a completely different approach (different
commands, different tool, different order of operations) and still pass,
as long as the final observable state satisfies the oracle. Conversely, a
solution that looks similar to the reference but leaves the system in the
wrong state will fail. This is what makes the benchmark "dynamic":
correctness is judged by execution, not by resemblance.

To evaluate a real LLM instead of the hand-written baseline/cheating
samples in `samples/llm_outputs.json`, use `generate_llm_samples.py`.
It supports four provider backends via `--provider`, so the same
workflow covers a proprietary API (Claude, ChatGPT) or an open-weight
model (anything on the Hugging Face Inference API, or a self-hosted
vLLM/TGI/Ollama server):

| `--provider` | What it calls | Install | API key |
|---|---|---|---|
| `anthropic` (default) | Claude models, Anthropic Messages API | `pip install anthropic` | `ANTHROPIC_API_KEY` |
| `openai` | GPT models, OpenAI Chat Completions API | `pip install openai` | `OPENAI_API_KEY` |
| `huggingface` | Any open-weight model on the HF Inference API/Providers (Qwen2.5-Coder, Llama-3.1, DeepSeek-Coder, ...) | `pip install huggingface_hub` | `HF_TOKEN` |
| `openai_compatible` | Any server speaking the OpenAI chat-completions wire format at a custom `--base-url` (self-hosted vLLM/TGI/Ollama, a HF Inference Endpoint, OpenRouter, Together, Fireworks, ...) | `pip install openai` | env var named by `--api-key-env` (default `OPENAI_API_KEY`) |

1. Install the one SDK you need and set the matching API key, e.g. for Claude:
```bash
   pip install anthropic
   export ANTHROPIC_API_KEY=...
```
2. Call the model on one case (or all of them) using each case's
   `task.txt` as the prompt. The script extracts the shell command(s) from
   the model's ```bash code block and writes them as a sample:
```bash
   # Claude
   python3 generate_llm_samples.py --provider anthropic \
       --model claude-sonnet-4-5 --case q74317699
   python3 generate_llm_samples.py --provider anthropic \
       --model claude-sonnet-4-5 --all

   # ChatGPT / GPT
   export OPENAI_API_KEY=sk-...
   python3 generate_llm_samples.py --provider openai \
       --model gpt-4o --all

   # An open-weight model via the Hugging Face Inference API
   export HF_TOKEN=hf_...
   python3 generate_llm_samples.py --provider huggingface \
       --model Qwen/Qwen2.5-Coder-32B-Instruct --all

   # A self-hosted / OpenAI-compatible endpoint (vLLM, TGI, Ollama, ...)
   export MY_ENDPOINT_KEY=...
   python3 generate_llm_samples.py --provider openai_compatible \
       --model meta-llama/Llama-3.1-70B-Instruct \
       --base-url https://your-endpoint.example.com/v1 \
       --api-key-env MY_ENDPOINT_KEY --all
```
   **Every run writes to its own new, auto-named file** —
   `samples/generated/<provider>__<model>__<timestamp>.json` — printed
   at the start of the run, e.g.:
```
   samples/generated/anthropic__claude-sonnet-4-5__2026-09-20_21-15-03.json
   samples/generated/openai__gpt-4o__2026-09-20_21-40-11.json
   samples/generated/huggingface__Qwen_Qwen2.5-Coder-32B-Instruct__2026-09-20_22-02-47.json
```
   Nothing is ever silently overwritten this way: a different model, or
   a re-run of the *same* model at a different time, always lands in its
   own file, so every run is automatically kept as a dated backup. Each
   sample inside the file also carries `"provider"`, `"model"`, and
   `"generated_at"` fields, so a file is self-describing even if you
   rename or move it later. (This is kept separate from
   `samples/llm_outputs.json`, which holds the hand-written
   `reference_solution` / `no_op_baseline` / `cheating_*` samples used to
   validate the oracle itself — that file is never touched by this
   script.) Each generated sample is written incrementally (after every
   case, not just at the end), so a `--all` run that fails partway
   through (rate limit, network error) doesn't lose everything already
   collected — check the printed list of failed cases at the end and
   re-run just those with `--case`.

   If you'd rather accumulate several models into one shared file as
   you go (instead of one file per run), pass `--out` explicitly — a
   sample for a `(case_id, model)` pair already in that file is
   replaced, everything else is kept:
```bash
   python3 generate_llm_samples.py --provider anthropic \
       --model claude-sonnet-4-5 --all --out samples/generated/compare.json
   python3 generate_llm_samples.py --provider openai \
       --model gpt-4o --all --out samples/generated/compare.json
```
3. Run the generated sample(s) through the same 5-stage harness, pointing
   `--samples` at whichever file you want to evaluate:
```bash
   # single case
   python3 run_single_case.py q74317699 --model claude-sonnet-4-5 \
       --samples samples/generated/anthropic__claude-sonnet-4-5__2026-09-20_21-15-03.json

   # full batch, one model's run
   python3 run_benchmark.py \
       --samples samples/generated/anthropic__claude-sonnet-4-5__2026-09-20_21-15-03.json
```
   To compare **multiple** models' separate per-run files in one
   `results.csv` (and therefore one `compute_pass_at_1.py` table), merge
   them first with `merge_samples.py` — it only reads the inputs and
   writes a new combined file, so the individual per-run backups are
   never modified:
```bash
   python3 merge_samples.py \
       samples/generated/anthropic__claude-sonnet-4-5__2026-09-20_21-15-03.json \
       samples/generated/openai__gpt-4o__2026-09-20_21-40-11.json \
       samples/generated/huggingface__Qwen_Qwen2.5-Coder-32B-Instruct__2026-09-20_22-02-47.json \
       --out samples/generated/compare_2026-09-20.json

   python3 run_benchmark.py --samples samples/generated/compare_2026-09-20.json
```
4. Summarize pass@1 across all cases, per model, from the resulting
   `results.csv`:
```bash
   python3 compute_pass_at_1.py --latest
   # or point at a specific run:
   python3 compute_pass_at_1.py results/2026-09-20_12-00-00/results.csv
   # save the summary table too:
   python3 compute_pass_at_1.py --latest --out results/pass_at_1_summary.csv
```
   Each row in `samples_file` is a single, unretried attempt at a case,
   so `oracle_passed` per `(case_id, model)` **is** the pass@1 signal for
   that attempt — `compute_pass_at_1.py` just aggregates it into
   `passed / attempted` per model and lists which case_ids failed.
   Pass `--strict` to also require `setup_ok`/`precondition_passed`,
   excluding cases where the harness environment itself misbehaved
   rather than the model's solution being wrong.

`run_single_case.py` and `run_benchmark.py` don't care whether a sample
came from a human or a model — they just run whatever `code` string is
attached to the sample through cleanup → setup → precondition →
`[code]` → oracle → cleanup, exactly as described above.

**Current limitations:**
- Code extraction is a naive regex for the first ```bash/```sh fenced
  block in the response — check the output of a single `--case` run
  before trusting `--all` on a new model. A model that ignores the
  "respond with ONLY a code block" instruction (common on smaller
  open-weight models) may need a stricter prompt or a smarter extractor.
- No retries/backoff beyond the incremental-write safety net above; a
  large `--all` run against many cases can still hit provider rate
  limits mid-run — pass `--sleep <seconds>` to space out calls.
- The Hugging Face Inference API's model availability and routing
  (`--hf-provider`) can change over time; if a call fails with a
  "model not supported by this provider" style error, try
  `--hf-provider hf-inference` explicitly or check the model's page on
  huggingface.co for which Inference Providers currently serve it.

## Requirements

Must run inside an environment with the relevant container runtime
actually installed (currently: containerd + runc). No mocking — every
case shells out to real runtime commands. Developed and tested inside a
Multipass Ubuntu 22.04/24.04 VM.

## License

MIT
