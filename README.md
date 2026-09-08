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
| 1 | Runtime Lifecycle & Execution | `lifecycle` |
| 2 | Runtime Configuration & Policy | `configuration` |
| 3 | Filesystem, Mount & Storage | `filesystem` |
| 4 | Identity, Privilege & Isolation | `isolation` |
| 5 | Networking & Connectivity | `networking` |
| 6 | Runtime Compatibility & Integration | `compatibility` |
| 7 | Diagnostics & Observability | `diagnostics` |

A case is placed in whichever category best matches what it's actually
testing — e.g. SO-75798292 (copying a host file into a running
containerd container's filesystem) lives under `filesystem`, not
`lifecycle`, even though it involves a running container, because the
thing being exercised is a filesystem/mount operation, not the
container's lifecycle itself.

See [`stackoverflow_question_task_mapping.csv`](./stackoverflow_question_task_mapping.csv)
for the full list of screened Stack Overflow questions and their taxonomy mapping.

## Structure

```
llm-container-runtime-benchmark/
├── README.md
├── stackoverflow_question_task_mapping.csv
├── conf/
│   └── config.yaml              # timeout, samples_file, results_dir — single source of config
│
├── cases/
│   ├── lifecycle/
│   ├── configuration/
│   │   └── q61058619/           # one case = one self-contained bash test kit
│   │       ├── setup.sh
│   │       ├── precondition.sh
│   │       ├── reference_solution.sh
│   │       ├── oracle.sh
│   │       ├── cleanup.sh
│   │       └── task.txt
│   ├── filesystem/
│   │   └── q75798292/
│   │       ├── setup.sh
│   │       ├── precondition.sh
│   │       ├── reference_solution.sh
│   │       ├── oracle.sh
│   │       ├── cleanup.sh
│   │       └── task.txt
│   ├── isolation/
│   │   └── q70714501/
│   │       ├── setup.sh
│   │       ├── precondition.sh
│   │       ├── reference_solution.sh
│   │       ├── oracle.sh
│   │       ├── cleanup.sh
│   │       └── task.txt
│   ├── networking/
│   └── compatibility/
│   └── diagnostics/
│
├── src/
│   ├── cfg_reader/
│   │   └── primary.py           # load(path) -> dict, reads conf/config.yaml
│   ├── utils/
│   │   └── shell.py             # subprocess wrapper shared by all cases
│   └── test_suites/
│       ├── lifecycle/
│       ├── configuration/
│       │   └── q61058619.py     # run_tests(sample, cfg) -> (cases, error_message)
│       ├── filesystem/
│       │   └── q75798292.py     # run_tests(sample, cfg) -> (cases, error_message)
│       │                        # orchestrates the bash scripts above,
│       │                        # does NOT reimplement test logic in Python
│       ├── isolation/
│       │   └── q70714501.py
│       ├── networking/
│       ├── compatibility/
│       └── diagnostics/
│
├── samples/
│   └── llm_outputs.json         # LLM-generated solutions to evaluate
│
├── results/
│   └── <timestamp>/results.csv  # run_benchmark.py writes here, one folder per run
│
├── requirements.txt
└── run_benchmark.py             # top-level driver: loads config + samples, calls the
                                  # right test_suites module, writes timestamped results
```

Empty category folders under `cases/` (nothing to test there yet) keep a
`.gitkeep` placeholder so the taxonomy is visible in the repo even before
every category has a case in it.

## Running

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

## Adding a new case

1. Decide which of the 7 taxonomy categories the case belongs to (by what
   it actually exercises, not just "it involves a container").
2. Add `cases/<category>/<case_id>/` with the 4 scripts + `task.txt`.
3. Add `src/test_suites/<category>/<case_id>.py` implementing
   `run_tests(sample, cfg) -> (cases, error_message)` — copy an existing
   one (e.g. `q75798292.py`) and change the script names / `CASE_DIR`.
4. Add samples for it to `samples/llm_outputs.json` with
   `"category": "<category>"`.

`run_benchmark.py` never needs to change — it dispatches purely by the
`category` + `case_id` fields on each sample.

## Requirements

Must run inside an environment with the relevant container runtime
actually installed (currently: containerd + runc). No mocking — every
case shells out to real runtime commands. Developed and tested inside a
Multipass Ubuntu 22.04/24.04 VM.

## License

MIT
