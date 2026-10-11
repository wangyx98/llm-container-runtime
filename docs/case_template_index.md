# Case template index: which finished case to copy from

Every case has the same five stages (cleanup, setup, precondition oracle, the solution, postcondition oracle, cleanup) and the same files:
`cases/<category>/<id>/{task.txt,setup.sh,precondition.sh,reference_solution.sh,oracle.sh,cleanup.sh}`, optional `helpers/`, plus
`src/test_suites/<category>/<id>.py` and `samples/fixtures/<category>/<id>.json`. This page says, for each kind of problem, which finished
case to open first, so a new case starts from one working case instead of from a survey of all of them. Read that case's `setup.sh`,
`cleanup.sh`, `helpers/lab.py` and the generator of its samples; read nothing else unless the pattern below is not enough.

**Scope.** This index is built from the Diagnostics cases, which are the ones that were worked through in detail, plus the few other cases
whose notes are in `docs/`. The other categories (compatibility, configuration, filesystem, isolation, networking) have many finished cases
that are not listed here yet. Add a row, and what it gives you, when you next build or revisit a case of those kinds, after reading that
case, so every row stays something that was checked.

Task wording: follow `docs/task_authoring_checklist.md` (no placeholders, literal names, one sentence on allowed tools, the sudo sentence, end
with "Return the commands needed to complete the task.").

## 1. Pick the pattern

| The problem is about... | Copy from | What it gives you |
|---|---|---|
| A CRI node (containerd's CRI plugin, `crictl`, pods and containers with names, namespaces, users) | `diagnostics/q71705752` | Private containerd on its own socket, `patch_config.py`, `mkimg.py` (offline OCI image), `lab.py up/more/check`, `verify.py`, the "node changes after the solution" oracle step |
| The same, but pods need a network namespace each (pause, sandbox, CNI) | `diagnostics/q71482106` | `cni-stub.sh` (a CNI plugin that sets nothing up), `/var/run/netns` bookkeeping in `cleanup.sh`, `idle.c` for the sandbox and workload programs |
| containerd namespaces, images, digests (`ctr`, `k8s.io` vs `default`) | `diagnostics/q71582111`, `diagnostics/q72541317` | Imported images in several namespaces, a record of names and digests in `truth.json`, an oracle that parses `NAMESPACE NAME DIGEST` |
| containerd run as a **systemd unit** and its **journal** (pull errors, log windows) | `diagnostics/q71584810`, `compatibility/q68630961` | Unit file, a registry stub (`registry.py`, `hosts.toml` through `config_path`), journal cursors |
| Container logs (CRI log files, partial/full records) | `diagnostics/q73176776`, `diagnostics/q73123230`, `diagnostics/q73415919` | Pods that write logs, `app.c`, log-file checks; q73415919 also changes a containerd config value and restarts the daemon |
| Logs of **stopped** containers, restarts (attempts), kubelet-style log rotation | `diagnostics/q71034357` | Containers that log what a script tells them to and exit with a chosen code (`app.c` with `x CODE`), a restart as a second attempt of the same name, `reopen.py` (ReopenContainerLog over raw gRPC, since `crictl` cannot) so a log really rotates into `N.log`, `N.log.TIMESTAMP` and `N.log.TIMESTAMP.gz`, `truth.json` with the bytes of each stream and the hashes of the log files, an oracle that stops a second container and asks again |
| Imported image can't be pulled or run (`ctr images import`, namespace `k8s.io`) | `diagnostics/q74804543` | Image import, tripwire for "must not pull" |
| A Go program that has to be changed (containerd client, Docker daemon query) | `diagnostics/q78432931`, `diagnostics/q76119356` | `starter/` source tree, compile-and-run oracle, a stub registry or daemon behind it |
| A private Docker daemon that stopped working | `diagnostics/q75346313` | `start-docker.sh`, a daemon with its own containerd and data directory |
| Bare runc (no containerd, no Docker), stuck process, stack trace | `diagnostics/q70089899` | Plain-bash case with no helpers: setup, precondition, oracle only |
| Registry, mirror or local image problems (microk8s, ctr run of a Docker image) | `compatibility/q69088569`, `compatibility/q59393496` | Case notes in `docs/` explain the decisions |

If none of the rows fits (a runtime not yet used, for example Podman or k3s), start from the nearest row only for `cleanup.sh` and the
oracle structure, and expect to write the rest.

## 2. What to copy, what to change

Copy the whole case directory, then change:

1. `CASE_ID` / `bench<id>` in every script, and every path under `/run`, `/var/lib` and `/tmp` that contains it. The case id is the only thing
   that keeps a case from touching another one's state.
2. `task.txt` and the shape of the file the solution writes (`verify.py` and `oracle.sh` follow from it).
3. `lab.py`: what is created, what is recorded in `truth.json` (from what the lab made and from `/proc`, never from the solution's tools),
   and what `more` changes after the solution has run.
4. The generator of the samples (keep it in a scratchpad, not in the repo): one correct reference, one valid alternative, a no-op, then wrong
   samples each aimed at one `verify.py` branch.

Keep as is: `cleanup.sh` (kill by `comm` plus a command-line regex, unmount deepest first, remove recorded runc state), the start of
containerd with `setsid -f`, the helper-hash check in `precondition.sh` and `oracle.sh`.

## 3. Sample design rules (what has worked)

- Every wrong sample exercises a **different** oracle branch; do not add two that fail at the same line.
- A replay or hard-coded sample is defeated by a change the oracle makes after the solution has run (`lab.py more`).
- A sample that changes the node (removes a pod, prunes containers) is caught by `lab.py check`, which runs before and after reading.
- A guess by name (for example, every process called `pause`) should look right for the first run and fail for the added one.
- Failure lines are short; anything of variable length goes last (the harness keeps about the last 500 characters of the oracle's output).
- Typical size: 9 to 11 samples.

## 4. Pitfalls already paid for

- `crictl` defaults to the CRI-O socket: always pass `--runtime-endpoint` **and** `--image-endpoint`. Flags such as `-o json` go before the
  positional arguments (`crictl inspectp -o json ID`).
- `crictl` shows `unknown` for pod and namespace unless the pod and container configs carry the kubelet labels
  (`io.kubernetes.pod.name`, `io.kubernetes.pod.namespace`, `io.kubernetes.pod.uid`, `io.kubernetes.container.name`).
- `crictl logs` reads only the current log file of a container: what the log rotation moved away is not in it. A rotated log is `N.log.TIMESTAMP`
  (timestamps sort in time order); all but the newest rotated file are gzipped. A record is `TIMESTAMP STREAM TAG TEXT`, TAG `P` for a part of a
  line that goes on in the next record (a write over 16 KiB), `F` for the end of a line.
- A restarted container is a NEW container (same name, next attempt number, its own log file `ATTEMPT.log`): the newest container of a name is
  not the one asked for. `crictl ps -a --name '^NAME$'` lists all attempts, newest first; `crictl inspect` gives `status.logPath`, `exitCode`, `reason`.
- `ctr` 2.x prints a cgroup-v1 deprecation warning on stderr: use `2>/dev/null` where its output is parsed.
- An imported (not pulled) image has no repo digest in `crictl`; the CRI plugin also adds `sha256:` entries for it in `k8s.io`.
- systemd 249: `journalctl -u UNIT --after-cursor` drops one line when the cursor entry is not selected by the unit filter; put cursors on
  entries of the unit itself. containerd logs an error and "stop pulling image" from different goroutines, in no fixed order.
- Never `pkill -f` a pattern that appears in your own command line; kill by exact `comm` and check the command line.
- A killed containerd leaves the net namespace mounts of its pods in `/var/run/netns`; record the new entries when the pod starts and
  remove only those.
- Image programs must be static (`gcc -static`) and built offline; Docker Hub, `mirror.gcr.io` and some package hosts are blocked in the
  sandbox, so the lab imports images it builds itself (`mkimg.py`).

## 5. How to verify a new case (the loop the series used)

1. Run every sample through `python3 run_single_case.py <bare id> --model NAME` (`--list` lists them); compare with the expected table.
2. Run the reference through a pty (`script -qec "..." /dev/null`) and as a non-root user with passwordless sudo.
3. Repeat the reference several times to catch flakes.
4. After `cleanup.sh`: no directories under `/run`, `/var/lib`, `/tmp` for the case id, no mounts, no processes, no entries left in
   `/var/run/netns` or in the shared runc root, compared with the count before the run.
5. The final report names: the loop command, the expected-results table, the residue commands, the helpers the case uses and whether each
   is necessary, and the commit message.
