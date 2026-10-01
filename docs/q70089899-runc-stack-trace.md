# Case q70089899 — "How to dump the stack trace of runc"

Status: **complete**. Verified in the cloud sandbox (runc 1.3.5): reference 20/20 PASS,
setup+precondition 30/30, 6 negative samples x3 all oracle-FAIL, no leaked processes/cgroups.
On the user's VM (Ubuntu 22.04, runc 1.3.4, sudo 1.9.9, 2026-10-01): all 7 samples behave as
expected (`reference_solution` PASS, the other six FAIL, no traceback, no leftover processes)
after the `shell.py` timeout handling and the `sudo timeout` sample fix described below.

Source: https://stackoverflow.com/questions/70089899/how-to-dump-the-stack-trace-of-runc
Category: Diagnostics & Observability. Task type: **diagnose and produce an artifact**
(deliverable is `/tmp/bench70089899/stacktrace.txt`, not a repaired system state).
Needs only `runc` (no containerd/ctr, no network, no extra packages).

## The SO answer being tested
Attach a reader to the stuck runc's stderr (`cat /proc/<pid>/fd/2`), then `kill -SIGQUIT <pid>`;
the Go runtime dumps all goroutine stacks to stderr and the process exits.

## How the "stuck runc" is reproduced (no reliance on a historical runc bug)
A `createContainer` hook (no timeout) that never returns wedges `runc init`. runc's stderr is a
named FIFO with a silent never-reading holder, so there is no log file to `cat`; the only way to
get the bytes is to tap the process's fd 2.

## Findings worth reusing (all verified empirically unless marked)
1. **`createRuntime` hook does NOT work for this.** It blocks the top-level `runc create`, which
   installs a catch-all signal forwarder that swallows SIGQUIT: no dump, process stays alive.
   `createContainer` hooks run inside the `runc init` child, which keeps Go's default
   dump-and-exit behavior. So the right process to signal is `runc init`, not `runc create`.
2. **runc 1.3 re-execs in stages**, so short-lived intermediate `runc init` processes exist next to
   the real one. Picking "the first `runc init`" races (~1 in 7-15 runs). The real stuck one is the
   `runc init` that has the hook's `sleep` as a child.
3. **Cleanup must not trust recorded PIDs alone.** A leaked orphan `runc init` (ppid 1) keeps the
   container cgroup busy and poisons every later run. Kill by cgroup membership
   (`/proc/*/cgroup` ending in `/<container id>`).
4. **Race-type bugs need many repetitions** (a 14% failure rate passes 5 runs ~47% of the time,
   20 runs only ~5%); this is different from a deterministic idempotency check.
5. Background processes started from a setup script need `setsid` + redirected stdio, otherwise
   `subprocess.run(capture_output=True)` waits forever on inherited pipes, and `sudo` may insert a
   pty relay between runc and the FIFO.
6. Tooling gotcha: `pkill -f "<pattern>"` inside an interactive agent shell can match (and kill)
   the shell's own command line. Use `pkill -x` / `pgrep -x` or anchored patterns.
7. **`timeout N sudo cmd` vs `sudo timeout N cmd`.** The negative sample
   `wrong_process_signal_top_level_runc_create` originally used `timeout 10 sudo cat ... &`
   followed by `wait`. In the cloud sandbox (sudo 1.9.15) it ended after 10 s; on the Ubuntu 22.04
   VM (sudo 1.9.9) it never ended and the harness gave up after the full timeout (180 s).
   Changing it to `sudo timeout 10 cat ...` fixed it on the VM (the sample now finishes by itself,
   no `[TIMEOUT]`). The likely mechanism (a hypothesis consistent with the result, not confirmed by
   inspecting the processes): unprivileged `timeout` can only signal `sudo`, and sudo 1.9.9 does
   not pass that SIGTERM on to its root `cat` child, which runs in sudo's pty session; with
   `sudo timeout`, `timeout` itself runs as root and kills `cat` directly. Rule of thumb for
   samples and solutions: put `sudo` in front of `timeout`, not behind it.
   The sandbox could not reproduce the hang, so this fix could only be validated on the VM.
8. **Harness timeout handling (`src/utils/shell.py`, shared by every case).** A hung LLM solution
   used to raise an uncaught `subprocess.TimeoutExpired`, which aborted the lifecycle with a
   traceback before the oracle and the final `cleanup.sh` ran. `run_script` / `run_shell_snippet`
   now catch it and RETURN a `ShellResult` with `timed_out=True`, `returncode=124` (GNU `timeout`'s
   code), the partial stdout/stderr captured so far, and a note
   `[TIMEOUT] killed after Ns without finishing ...` appended to stderr. `.ok` is false for a
   timed-out result, so the lifecycle continues: oracle (normally FAIL), then cleanup.
   Caveats:
   - `subprocess.run(timeout=)` only kills the direct child (`bash`); background grandchildren of a
     timed-out solution survive as orphans until that case's own `cleanup.sh` removes them (that is
     why cleanup kills by cgroup / anchored patterns).
   - A snippet that exits 0 but leaves a background process holding the stdout/stderr pipes also
     blocks until the timeout and is reported as a timeout.
   - There is no dedicated results column for it; the only trace is `[TIMEOUT]` at the END of
     `solution_stderr`. `run_single_case.py` prints only the first 300 characters of long fields,
     so the note is cut off there; check it with a small script that prints the tail, or read the
     CSV from `run_benchmark.py`.
   - Possible follow-up (not done): add `cases["solution_timed_out"] = solution.timed_out` to each
     test suite for a proper column.

## Oracle (anti-cheat) summary
`SIGQUIT: quit` header, >= 4 goroutines, frames specific to this hang (`libcontainer`,
`prepareRootfs`, `Hook`), bundle `config.json` hash unchanged, and the ORIGINAL stuck `runc init`
must be gone (a fabricated file leaves it hanging). Pasting the well-known seccomp/ExportBPF trace
from the GitHub thread fails the frame check.

How each negative sample fails (observed on the VM): `naive_retry_same_command` — no `SIGQUIT: quit`
header; `wrong_process_signal_top_level_runc_create` and
`wrong_order_signal_before_attaching_reader` — `stacktrace.txt` missing or empty;
`cheating_paste_known_seccomp_trace` — `prepareRootfs` frame missing;
`cheating_fabricate_matching_frames` — original `runc init` still alive (the only check that
catches it).

## Samples
`reference_solution`, `no_op_baseline`, `naive_retry_same_command`,
`wrong_process_signal_top_level_runc_create`, `wrong_order_signal_before_attaching_reader`,
`cheating_paste_known_seccomp_trace`, `cheating_fabricate_matching_frames`.

## Not verified
cgroup v2-only hosts (cleanup's cgroup-name match should apply, since the name is `/bench70089899`,
but it was only exercised on a v1/hybrid sandbox and on the user's Ubuntu 22.04 VM).
The exact cause of the `timeout sudo` hang on sudo 1.9.9 (see finding 7).
