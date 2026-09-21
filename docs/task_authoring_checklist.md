# Task.txt Authoring Checklist: Avoiding Non-Capability Failure Modes

## Why this exists

When we ran GPT-4o (a strong, instruction-following model, `max_tokens=2048`,
no truncation) against 10 already-built cases, roughly half the failures had
nothing to do with the model's container-runtime knowledge. They came from
how the `task.txt` itself was phrased, or from ambiguity about the execution
environment that any model — strong or weak — has no way to resolve on its
own in a single-shot, non-interactive call.

This matters for benchmark validity: if a case fails for a reason unrelated
to container-runtime reasoning, that failure is noise, not signal. This
checklist exists so future cases fail (or pass) for the *right* reason.

**Important scope note:** this checklist is for the humans authoring
`task.txt` files. It is never read by `generate_llm_samples.py` and is never
sent to any model's API — only the matching `task.txt` is. If you want a
rule to apply automatically to every API call regardless of which case,
that belongs in `generate_llm_samples.py`'s `PROMPT_TEMPLATE`, not here.

The dividing line used throughout: **if fixing it would remove ambiguity
that has nothing to do with the runtime bug being tested, fix it. If fixing
it would remove the actual reasoning/knowledge the case is meant to test,
don't.**

## Failure modes found so far, with real evidence

### 1. Placeholder syntax (`<xxx>`) in the model's answer — avoidable at authoring time

**Root cause, confirmed by direct evidence:** models don't invent placeholder
syntax at random — they copy it from the task description. In
`cases/configuration/q61058619/task.txt`, the bug-reproduction example reads:

```
$ sudo crictl create <pod-id> /tmp/bench61058619_container.json /tmp/bench61058619_pod.json
```

GPT-4o's actual answer for this case contained the literal string
`sudo crictl create <pod-id> ...` — copied straight from the task text. Bash
parses `<pod-id>` as input redirection from a file named `pod-id`, so the
command fails immediately, unrelated to whether the model understood the
seccomp bug.

Compare this to `cases/compatibility/q65650082/task.txt` and
`cases/filesystem/q69295491/task.txt`, which never use bracket placeholders
anywhere, because every name the model needs ("bench65650082-pod",
"bench65650082", etc.) is given as a fixed, literal value in the task text.
GPT-4o produced zero placeholder issues on either of those.

**Rule:**
- Never use `<xxx>` bracket notation anywhere in `task.txt`, including in
  illustrative/reproduction command examples. If you need to show the shape
  of a command with an unknown value, spell it out in prose ("the pod ID
  returned by `crictl runp`") instead of inline brackets in a code block.
- Any name that's fixed by the case design (pod name, container name,
  bundle path) should be given as a literal, concrete string in the task
  text — that's environment setup, not the bug being tested.
- Any value that's genuinely only known at runtime (a pod ID assigned by
  `crictl`, a port the model must pick itself) should be called out
  explicitly in prose: state that it isn't given, and that the script must
  discover/generate it via command substitution. Give one example discovery
  command if it helps ("e.g. `crictl pods --name X -q`") — this isn't
  spoon-feeding the fix, discovering an ID is a mechanical prerequisite, not
  the runtime problem itself.

**Before, applied to q61058619:**

```
This file currently contains invalid JSON (it is not a valid seccomp
profile), which causes container creation to fail, e.g.:

    $ sudo crictl create <pod-id> /tmp/bench61058619_container.json /tmp/bench61058619_pod.json
    FATA[0000] creating container failed: ... seccomp ...
```

**After:**

```
This file currently contains invalid JSON (it is not a valid seccomp
profile), which causes container creation to fail. Attempting to create
the container against the already-running pod sandbox (using the pod ID
`crictl pods --name bench61058619 -q` returns) fails with:

    FATA[0000] creating container failed: ... seccomp ...

Your solution will need to look up that pod ID itself at runtime — it is
not given above since it's only assigned once the pod sandbox starts.
```

### 2. Ambiguous privilege / tool-chain assumptions — avoidable at authoring time

**Evidence:** `cases/networking/q73631968/reference_solution.sh` uses
`sudo nerdctl run ...`. GPT-4o's answer dropped `sudo` and ran plain
`nerdctl run ...`, which made nerdctl default to rootless mode — a mode this
environment's setup never configured (only rootful containerd is running).
The failure (`rootless containerd not running?`) is about a guess the model
had no way to resolve, not about the actual networking fix.

**Rule:**
- State the privilege model explicitly wherever it isn't obvious. A
  boilerplate line works for most cases: *"The current user has passwordless
  sudo. Unless stated otherwise, assume container-runtime commands need
  `sudo`."* Consider adding this once, globally (e.g. as a fixed preamble in
  `generate_llm_samples.py`'s `PROMPT_TEMPLATE`, or repeated per-case if
  cases are meant to be self-contained prompts on their own).
- If a case's environment only has one of {rootful, rootless} containerd/
  nerdctl configured, say so directly, the way `q65650082` says "no docker,
  no podman, no plain ctr/containerd."

### 3. Tool-choice ambiguity — already handled well in most existing cases, keep doing this

`q65650082`, `q69295491`, and `q75798292` all explicitly state which CLI is
required/forbidden ("Use crictl against the real CRI-O endpoint... no other
runtime CLI" / "You may use ctr, containerd/runc-related commands..."). None
of these three produced a tool-choice failure in the GPT-4o run. Keep this
pattern for every new case — one sentence stating the allowed/forbidden
tool(s) up front removes an entire class of ambiguity-driven failures.

### 4. Genuine reasoning/knowledge gaps — do NOT patch these by adding hints

Three cases in the GPT-4o run failed for reasons that have nothing to do
with placeholders, permissions, or tool choice — the model reasoned
incorrectly about the actual container-runtime concept being tested:

- **`q61994952`**: task.txt already states plainly that a privileged
  container gets "(near-)ALL" capabilities vs. a normal container's 3
  defaults. GPT-4o's generated check compared the capability list's length
  against an invented list of 5 unrelated capability names instead of
  checking for a near-full set. The task text isn't ambiguous here — the
  model's operationalization of "near-all" was wrong.
- **`q70714501`**: GPT-4o invented a non-existent containerd `config.toml`
  key (`io.containerd.grpc.v1.cri = {"group"=...}`) instead of the real
  `[grpc]` section's `gid =` field. This is a narrow, real knowledge gap
  about containerd's actual config schema.
- **`q61058619`** (the reasoning half, not the placeholder half): GPT-4o
  tried `jq . broken-seccomp.json` to "fix" a file the task explicitly says
  contains invalid JSON — conflating a formatting problem with a content
  problem.

**Rule: leave these task.txt files as they are.** These are exactly the
kind of failure this benchmark exists to surface. Adding hints here would
quietly turn the benchmark into a recall/formatting test instead of a
reasoning test, and would make pass@1 numbers look better without the
model actually being more capable.

**One legitimate design lever, not a default:** for cases like `q70714501`
that hinge on recalling an obscure config file's exact schema, you can
*choose* to paste the current file's relevant contents into task.txt (the
way a real engineer would `cat` the file before editing it). That shifts
what's being tested from "can you recall this syntax from memory" to "given
the actual file, can you reason out the correct edit" — both are valid
things to test, but pick deliberately per case, not as a blanket fix applied
because pass rate looked low.

## Pre-flight checklist — run through this before ever pointing an LLM at a new task.txt

- [ ] No `<xxx>` bracket placeholders anywhere in the text, including inside
      example/reproduction command blocks.
- [ ] Every name/path/value the solution needs that's fixed by the case
      design is given as a literal string.
- [ ] Every value that's only known at runtime is explicitly flagged as
      "not given, discover it yourself," ideally with one example discovery
      command.
- [ ] The required/forbidden tool(s) (crictl vs nerdctl vs ctr vs runc vs
      podman) are stated in one explicit sentence.
- [ ] The privilege model (sudo required? rootful vs rootless?) is stated or
      inherited from a shared boilerplate.
- [ ] If the task hinges on recalling a specific, narrow piece of config
      syntax, that's a deliberate choice (recall test) — not an oversight.

## Appendix: evidence log, GPT-4o run (`openai__gpt-4o__2026-09-21_12-32-43.json`)

| case_id | issue | fix category |
|---|---|---|
| q61058619 | literal `<pod-id>`/`<container-id>` in generated code, copied from task.txt's own example | (1) placeholder — fix task.txt |
| q61058619 | `jq .` used to "fix" a file the task says is invalid JSON | (4) reasoning gap — leave as-is |
| q73631968 | missing `sudo`, plus literal `<NEW_HOST_PORT>` placeholder | (1)+(2) — fix task.txt / add privilege boilerplate |
| q61994952 | capability-count check compares against an invented 5-item list instead of a near-full-set threshold | (4) reasoning gap — leave as-is |
| q70714501 | hallucinated containerd `config.toml` key/section | (4) knowledge gap — leave as-is (or apply the "show file contents" lever deliberately) |
| q65650082, q69295491, q62887953, q75798292, q74317699 | no placeholder/permission/tool issues found | n/a — these task.txt files are good reference examples |
| q62408028 | direct `ip addr` manipulation on `cni0`; open question whether "Operation not permitted" (seen on the earlier Qwen run) is an execution-environment privilege issue rather than a model issue | needs a real run to confirm before categorizing |