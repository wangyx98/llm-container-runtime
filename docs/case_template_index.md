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
| Processes of containers and the host (which pod/container owns a PID; cgroup, parent chain, same-named pods, first process vs descendants) | `diagnostics/q70948748` | `app.c` that starts a process tree on a script line (`t`: child and grandchild, `r`: an orphan the first process takes over; processes named with `prctl`), pods of the same name in two namespaces with random UIDs, a decoy host process, a `truth.json` from the host process table, a verify that asks for several PIDs (a different depth each) and re-asks after the lab adds pods and containers |
| containerd namespaces, images, digests (`ctr`, `k8s.io` vs `default`) | `diagnostics/q71582111`, `diagnostics/q72541317` | Imported images in several namespaces, a record of names and digests in `truth.json`, an oracle that parses `NAMESPACE NAME DIGEST` |
| An `ctr images list` **filter** (select images by ref: the grammar of `name~=`, `==`, `!=`, escaping) in the namespace `k8s.io` | `diagnostics/q66754136` (from `diagnostics/q71582111`) | Copy of q71582111's node and image import (no CRI, no containers), `lab.py` that imports 9 refs into `k8s.io` and 2 into `default` (look-alike refs: a dot vs a dash, a prefix of another name, `.io/`) and `more` that imports 4 more, `verify.py` that runs the solution's script `ref-filter.sh TEXT OUT` for each text, runs `ctr` with the single filter line, and compares the refs with those that contain the text as plain text; `lab.py check` for images and content stores unchanged |
| A **MicroK8s-like node**: `ctr` shows nothing because the workload is in the namespace `k8s.io` (default is empty); list containers with image digest and task PID, images with digests; a second socket of the host that must stay untouched | `diagnostics/q61055917` (from `diagnostics/q67990667`) | Copy of q67990667's node, `idle.c`, `mkimg.py` and shim-child PID truth, with the workload in the literal namespace `k8s.io` and 64-hex IDs recorded in `ids.txt` (cleanup removes `/run/containerd/runc/k8s.io/<id>` for those only), `mkimg.py` output used as the digest truth (two images named `pause:3.1` from different registries, one image no container uses), `tap.py` (a listener on another socket that only logs connections: `verify.py` fails when the log is not empty; precondition checks it without connecting), `lab.py more` that kills and removes a task, starts a created container and adds an image and container |
| **Docker's runc and containerd** found on a host where the defaults show nothing: the runtime root (`runc --root <exec-root>/runtime-runc/<namespace> list`), the containerd socket and namespace, Docker's images in containerd, runc has no images | `diagnostics/q57009928` (daemon start from `diagnostics/q75346313`) | A private containerd plus a private `dockerd` (`--exec-root`, `--containerd`, `--feature containerd-snapshotter=true`, no bridge) started inline in `setup.sh`, the exec root and the containerd socket with a random part chosen at setup (`.bench/rand`) so no path can be hardcoded, `mkimg.py REF APP OUT` (a `docker save` archive, `IMAGE_REF` in the config so two refs are two images), `lab.py up/more/check` (containers from `docker run -d`, PIDs from the shim's child in `/proc`, `more` loads an image, starts a container and removes one while the first keeps running), `verify.py` with the `runc_has_images` flag that must be false |
| **Docker's runc root when the daemon is configured by a FILE**: `runc list` is empty, the root (`<exec-root>/runtime-runc/moby`) is not on the command line (`ps | grep runtime-root` finds nothing), only runc's root and the containers (full IDs, PIDs), no containerd socket or images | `diagnostics/q61738905` (thin variant of `diagnostics/q57009928`; copy that case, not this one, when containerd or images are asked for) | The same private containerd + `dockerd` start as q57009928 with `--host` and `--config-file` only: `daemon.json` holds `exec-root` (random name), `containerd`, `data-root`, `pidfile`, `group`, `features.containerd-snapshotter` and the no-bridge options; `lab.py up/more/check` (`docker run -d`; the PID is `docker inspect` State.Pid, so no shim lookup), `verify.py` with a hint for short IDs; helpers `app.c`, `mkimg.py`, `patch_config.py` copied unchanged |
| **Docker and the CRI on one containerd**: which client shows which containers (`docker ps`, `crictl ps` / `crictl pods`, `ctr -n NAME containers ls`), the containerd namespaces `moby` and `k8s.io`, default empty, the Kubernetes namespace of a pod that is not a containerd namespace | `diagnostics/q48616250` (Docker start from `diagnostics/q57009928`, CRI pod from `diagnostics/q67480710`) | One private containerd with the CRI plugin and a private `dockerd --containerd <that socket>`, one `app.c` image (`serve` waits, `attr` exits) built once by `mkimg.py` and loaded with `docker load` and `ctr -n k8s.io images import` (the same archive is the sandbox image under another ref), `lab.py up/more/check` (Docker containers with `docker run -d`, a pod with `crictl runp` / `create` / `start`, one exited container of each, `more` starts one and removes one in each), `verify.py` with one exact ID set per API plus its socket and containerd namespace |
| **Bare runc containers** and the CPU time a container has used (cgroup v1 `cpuacct.usage` / v2 `cpu.stat`): the cgroup of a container is found from its first process (`runc state` PID, `/proc/PID/cgroup`), the counter is the cgroup's, not the process's; a container started after the solution with another ID and cgroup path | `diagnostics/q64071782` (runc part from `diagnostics/q70089899`) | No daemon, no image: a root-owned bundle per container below `/var/lib/bench<id>` (a rootfs with ONE static program `app.c`: `init` sleeps and forks `burn`, a worker that uses the CPU time it is told to through a control file and reports what its own CPU clock says) started with `runc run -d`; `lab.py up/more/check` (the first two containers get an absolute `cgroupsPath` `/bench<id>-RAND/ID` below a shared random parent, the one started by `more` none: runc chooses the path), `burn(name, ms)` is the independent truth; `verify.py` runs the script around windows in which only the other / only this container works and compares growth with what the worker reported; works with cgroup v1 and v2 |
| What the CRI says about an **image** (`crictl images` / `inspecti`: config fields such as `created`, image ID, several names, a retagged name) | `diagnostics/q70986540` | `mkimg.py REF VARIANT CREATED OUT` (the `created` field of the config is set, or absent with `-`; a history that never gives the same date), a `truth.json` of `{name: {id, created}}` with timestamps in the form Go writes back, `lab.py more` that imports an image and moves a name, a verify that tells an import time from a build time and a lost fraction from a different instant |
| Containers made with plain `ctr` (no CRI): the record of a container (image, runtime, labels, OCI spec: env, mounts) and the state and PID of its **task** (`docker inspect`), several namespaces, the same ID in more than one | `diagnostics/q67990667` | `lab.py` that imports an image per namespace (`mkimg.py REF VARIANT BINARY NAME OUT`, image env `IMAGE_REF`) and makes containers with `ctr run -d` (running) or `ctr containers create` (no task), namespaces named `bench<id>-...`, random labels, env and bind mounts per container, a `truth.json` whose PIDs come from the shim's child in `/proc`, `lab.py more` that starts a task, kills a process (stopped task) and removes a task and adds a container in a new namespace, a `verify.py` that runs the script, calls `lab.py check` (nothing created, started or relabelled) and then compares field by field |
| containerd run as a **systemd unit** and its **journal** (pull errors, log windows) | `diagnostics/q71584810`, `compatibility/q68630961` | Unit file, a registry stub (`registry.py`, `hosts.toml` through `config_path`), journal cursors |
| Container logs (CRI log files, partial/full records) | `diagnostics/q73176776`, `diagnostics/q73123230`, `diagnostics/q73415919` | Pods that write logs, `app.c`, log-file checks; q73415919 also changes a containerd config value and restarts the daemon |
| A log **collector** (Fluent Bit; Fluentd is the same job with other syntax) reading CRI log files in the kubelet layout: parser or format migration (Docker JSON to CRI), symlinks, following live appends | `diagnostics/q67480710` (multi-line events and the Fluent Bit multiline filter: `diagnostics/q73123230`) | The pinned Fluent Bit unpacked from the project's apt repo and cached (`setup.sh`, `FLUENT_BIT_BIN` to use another binary), `flb.sh start/stop`, `collector.py` (the local JSON collector: Fluent Bit's http output `json_lines` is appended to `records.jsonl`), the lab's `main.conf` that includes the solution's `pipeline.conf` and `parsers.conf`, a pod whose log directory is `WORK/var/log/pods/NAMESPACE_POD_UID` with the kubelet's `containers/POD_NAMESPACE_CONTAINER-CID.log` symlinks made by the lab, a workload (`app.c serve FILE`) that logs the lines of a script on stdout or stderr, a verify that matches records to lines by a marker and compares `log` and `stream`, `lab.py check` that proves the runtime's files and symlinks were not touched |
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
- The image ID the CRI shows is the digest of the image config. `crictl inspecti -o json ID` has the config as the CRI reads it in
  `info.imageSpec` (`created` is absent when the config has none; timestamps come back in Go's form: nine-digit fractions without trailing zeros,
  `Z` or a numeric offset). `crictl images` lists images of the namespace `k8s.io` by `repoTags`; a name added there with `ctr -n k8s.io images tag`
  appears in the CRI without a restart. The blobs of an import and the image record are as old as the import, whatever the config says.
- A restarted container is a NEW container (same name, next attempt number, its own log file `ATTEMPT.log`): the newest container of a name is
  not the one asked for. `crictl ps -a --name '^NAME$'` lists all attempts, newest first; `crictl inspect` gives `status.logPath`, `exitCode`, `reason`.
- `ctr` 2.x prints a cgroup-v1 deprecation warning on stderr: use `2>/dev/null` where its output is parsed.
- An imported (not pulled) image has no repo digest in `crictl`; the CRI plugin also adds `sha256:` entries for it in `k8s.io`.
- systemd 249: `journalctl -u UNIT --after-cursor` drops one line when the cursor entry is not selected by the unit filter; put cursors on
  entries of the unit itself. containerd logs an error and "stop pulling image" from different goroutines, in no fixed order.
- CRI namespace modes: `namespace_options` is an enum with POD = 0 (the default), CONTAINER = 1, NODE = 2. Set `pid: 1` in the pod AND in each
  container config to get what the kubelet gives (a PID namespace per container); with the default all containers of a pod share one PID namespace
  with the pause process as its first process (which then takes over the orphans, and a container's first process is not PID 1). Unset `network` is
  POD (a netns of its own: it needs a CNI plugin, see q71482106).
- A container's processes are in a cgroup `/k8s.io/<container id>` (cgroup v1 on every controller line, v2 on the one `0::` line): the 64
  hexadecimal characters are in `/proc/PID/cgroup` for every descendant. `/proc/PID/environ` and `ns/*` of a root-owned process need root: in a
  script run by a normal user, `sudo cat FILE | ...`, never `sudo cmd < FILE` (the redirect runs as the user).
- Plain `ctr` (no CRI): a container's record (`ctr -n NS containers info ID`: `Image`, `Runtime.Name`, `Labels`, `Spec.process.env`, `Spec.mounts`) has
  nothing about the task; `ctr -n NS tasks ls` has `TASK PID STATUS` (RUNNING, STOPPED, ...), and a container with no task is not in it. A task whose process
  was killed stays STOPPED with its old PID until `tasks delete`. `Labels` also holds labels of the image config (`io.containerd.image.config.stop-signal`,
  image labels): compare the labels the lab set, not the whole object. `ctr containers info --spec ID` prints only the spec. `ctr tasks start ID` without
  `-d` stays attached (it blocks the tool); use `-d`. `ctr containers label ID` with no label is an error.
- runc keeps its state below `/run/containerd/runc/<containerd namespace>/<container id>`, shared by every containerd of the machine: name the namespaces
  of a case `bench<id>-...` so cleanup removes `/run/containerd/runc/bench<id>-*` and never another containerd's directory.
- The PID of a container's first process, independent of ctr: the child of the `containerd-shim` process whose command line has `-namespace NS -id ID`.
- Log collectors in the kubelet layout: a CRI log file is written by containerd as `TIMESTAMP STREAM F|P TEXT` (the timestamp has the host's UTC
  offset, not always `Z`; `P` marks a part of a line longer than 16384 characters). The directory of `log_path` is made by the runtime; the
  `containers/` symlinks are made by the kubelet, so the lab makes them. With the Docker JSON parser on such a file every line of a Fluent Bit
  `tail` input fails to parse and comes out as `{"log": WHOLE_LINE}`; with a `cri` regex parser (`stream`, `log` captured) or the tail input's built-in
  `multiline.parser cri` it comes out as `{stream, log}`. A `Parser` name that `Parsers_File` does not define stops Fluent Bit at start.
- Fluent Bit and the Fluentd gem cannot be fetched in the Claude sandbox (packages.fluentbit.io and index.rubygems.org are blocked by its egress
  policy): a case that runs them is verified for real on the VM. In the sandbox a stand-in (not committed) that implements only the used part of
  the configuration (`FLUENT_BIT_BIN` points to it; its comm must be `fluent-bit`, so use `#!/usr/bin/python3`, not `env`) exercises the lab, the
  collector and every branch of the oracle.
- Never `pkill -f` a pattern that appears in your own command line; kill by exact `comm` and check the command line. The same goes for
  `kill_ours bash`: the shell running the test, or the tool's own `bash -c` with the case's paths in its text, matches `$WORK_DIR` and is killed.
  Start a long-lived host process with `exec -a PATH-IN-WORK_DIR sleep N` so it is a `sleep` that `kill_ours sleep` can find.
- A killed containerd leaves the net namespace mounts of its pods in `/var/run/netns`; record the new entries when the pod starts and
  remove only those.
- Image programs must be static (`gcc -static`) and built offline; Docker Hub, `mirror.gcr.io` and some package hosts are blocked in the
  sandbox, so the lab imports images it builds itself (`mkimg.py`).
- The grammar of `ctr images list` filters (containerd `filters` package): the field is `name` (the ref); a field that does not exist, such as `ref`,
  lists nothing with status 0. `~=` is an unanchored regular expression, `==` and `!=` are exact, a comma inside one filter is AND, several
  filter arguments are OR. In a quoted value a backslash has to be doubled (`name~="bitnami/kafka:2\\.7\\.0"`; one backslash gives "illegal escape sequence"),
  quote any value that holds regular expression characters. The CRI plugin of `k8s.io` also adds `sha256:...` entries, so a case about names
  compares `images list -q` with the refs the lab imported. The filter goes to `ctr` as ONE argv element (it has no shell to quote it).
- A case that uses the real namespace name `k8s.io` for containers (the point of the question) shares `/run/containerd/runc/k8s.io/` with every other containerd of the
  machine: give the containers random 64-hex IDs, write each ID to `.bench/ids.txt` BEFORE creating the container, and let `cleanup.sh` remove only those directories
  (never the whole `k8s.io` directory, which may belong to a real node). In `k8s.io` the CRI plugin lists every imported image a second time under its bare ID
  (`sha256:...`); the lab leaves those entries out of its record and the oracle lets the solution list them or not.
- To forbid a connection to a second socket, put a listener there (`tap.py`) that logs and closes; checking it must not connect (no `ctr version`). A real second
  containerd would also work but gives nothing more: the mistake it catches is the call, not the data.
- `runc --root DIR list` creates DIR when it does not exist (even for `list`): a sample that tries a hardcoded root must test `isdir` first, or the sample leaves
  directories behind. The exec root of a private `dockerd` is not readable for the current user: read it with `sudo ls` / `sudo test` in `lab.py` and `precondition.sh`
  (the case passed as root and failed as the non-root user until then).
- Docker keeps its images in containerd only with the containerd image store (`--feature containerd-snapshotter=true`, Docker 24 or newer; the default of Docker 29):
  they are then in the namespace `moby` as `docker.io/NAME:TAG`, and Docker and `ctr` agree on the digest. With the classic graph driver containerd has none, so
  `lab.py` stops with a clear message when the image is not there. A private `dockerd` also leaves `/run/docker/plugins`, which any Docker host has.
- With one containerd shared by Docker and the CRI each client has its own set: Docker deletes a container from containerd when it stops, so `ctr -n moby containers ls` shows the
  RUNNING Docker containers only while `docker ps -a` shows all; the CRI keeps exited containers, and its pod sandbox is a container of containerd in `k8s.io` that `crictl ps` does not
  list (`crictl pods` does). The containers of a pod run in the sandbox's shim (its `-id` is the sandbox ID), so the "child of the shim started for this ID" PID of q67990667 only
  works for plain `ctr` and Docker containers; for CRI containers record `crictl inspect` `info.pid` once, with the start time from `/proc/PID/stat`, and compare that later.
- crictl 1.34 checks the image service too: give it `--runtime-endpoint` AND `--image-endpoint`, or it dials the default CRI-O socket and fails.
- `sudo rm -rf /run/containerd/runc/*/"$id"` does nothing for a user who is not root: `/run/containerd/runc` is root-only, so the glob is expanded by the user's shell and stays a
  literal `*`. Use `sudo sh -c 'rm -rf /run/containerd/runc/*/"$1"' _ "$id"` (as q48616250 does).

- Bare runc: `runc run -d` leaves the container's stdout/stderr attached to the runc process' pipes; start it from Python with the output sent to a FILE, not to `capture_output` (the container holds the pipe open for ever and `subprocess.run` never returns).
  `runc state ID` has the PID of the first process but no cgroup path (runc 1.1); the cgroup is in `/proc/PID/cgroup`. A relative or missing `cgroupsPath` is placed below the cgroup of whoever ran runc (`/ID` at the root in the sandbox,
  below the session scope on a systemd host), an absolute one is used as given; `runc delete -f` removes the container's cgroup but not the parent directory made for an absolute path: `cleanup.sh` removes `bench<id>*` directories
  with `sudo find /sys/fs/cgroup -maxdepth 8 -depth -type d -name 'bench<id>*' -exec rmdir {} \;`.
- CPU time of a cgroup: v1 `cpuacct.usage` is nanoseconds (the hierarchy may be mounted as `cpuacct` or `cpu,cpuacct`: find it in `/proc/self/mountinfo`), v2 `cpu.stat` `usage_usec` is MICROseconds and exists in a cgroup even when the cpu controller is not
  enabled for it; `runc events --stats` gives `data.cpu.usage.total` in nanoseconds on both. A host in hybrid mode (the sandbox) has both a v1 `cpuacct` mount and a unified mount at `/sys/fs/cgroup/unified`: decide the version by the `cpuacct` mount first.
  To test the v2 branch without a v2 host: `unshare -m bash -c 'umount -R /sys/fs/cgroup && mount -t cgroup2 none /sys/fs/cgroup && python3 run_single_case.py ID'` (the v1 mounts must be unmounted, not only covered: mountinfo still lists covered mounts).
- A process in a container whose root is root-owned but which has only runc's default capabilities (no `CAP_DAC_OVERRIDE`) cannot write into a directory owned by the user who runs the lab: `chmod 777` the control directory that is bind mounted
  (the case passed as root and failed as the non-root user until then). After `runc delete -f` the killed processes may be zombies for a few seconds in the sandbox (its PID 1 does not reap at once): a residue check of `pgrep -cx app` is only valid a few seconds later.
- A counter that grows with a process that is controlled by the lab can be verified exactly: the worker reports the CPU time it used (`CLOCK_PROCESS_CPUTIME_ID`) and the counter of its cgroup must grow by that (plus a little polling), so the oracle needs no tolerance for noise
  on the machine; make the other container (not the target) work in a separate window to catch a counter that holds both (the parent cgroup).

- Docker 29 (containerd image store by default) does NOT start a containerd of its own: without `--containerd` / `"containerd"` in `daemon.json` it dials `/run/containerd/containerd.sock` and `docker run` fails with "connection refused"; the
  classic store (`"features": {"containerd-snapshotter": false}`) does not help. A private `dockerd` therefore always needs a private containerd (q57009928's start). Every `dockerd` option except `--host` can sit in `daemon.json`
  (`--config-file`); an option named both on the command line and in the file is an error.
- Never prove "nothing shows runtime-root" with `ps aux | grep -c ...`: the command line of the shell that runs the check (or of a tool call that quotes the word) matches. Look at the command lines of the processes by NAME
  (`pgrep -x dockerd`) instead. And never run `runc --root SOMEDIR list` in a precondition for a directory that may be real (`/var/lib/docker/containers`): runc creates a missing root.
- A script that hardcodes Docker's usual root (`/var/run/docker/runtime-runc/moby`) must test `-d` first (the sample), or it leaves the directory behind; on a host with a system Docker the directory exists and the precondition checks that it holds nothing.

## 5. How to verify a new case (the loop the series used)

1. Run every sample through `python3 run_single_case.py <bare id> --model NAME` (`--list` lists them); compare with the expected table.
2. Run the reference through a pty (`script -qec "..." /dev/null`) and as a non-root user with passwordless sudo.
3. Repeat the reference several times to catch flakes.
4. After `cleanup.sh`: no directories under `/run`, `/var/lib`, `/tmp` for the case id, no mounts, no processes, no entries left in
   `/var/run/netns` or in the shared runc root, compared with the count before the run.
5. The final report names: the loop command, the expected-results table, the residue commands, the helpers the case uses and whether each
   is necessary, and the commit message.
