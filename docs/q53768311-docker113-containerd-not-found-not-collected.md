# q53768311 — Un-responsive docker containers (Docker 1.13.1: Up, but exec says "containerd: container not found") — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-20). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
Docker 1.13.1 (API 1.26, Go 1.7.5, containerd of that era). Containers show Running/Up in `docker ps`; `docker exec` fails with `rpc error: code = 2 desc = containerd: container not found`; `ps -aef` shows no related processes. dockerd log: `containerd: get exit status ... process has not exited`. One answer: fixed since 17.12, upgrade (18.03 is the latest supported); the asker cannot find the line in the changelog; the answerer's comment points to old moby issues (35091, 22909) and docker/for-linux. No trigger, no timeline, no recovery requirement, no data constraints.

## Why it was not collected
- The original stack (Docker 1.13, containerd 0.2, old runc, kernel of 2018) does not run on the VM (Docker 27, cgroup v2, kernel 5.15); the trigger is unknown (same position as q65131955 and q48609712).
- A modern stack does not reach this state by itself. Measured in the sandbox on 2026-11-20 (x86_64, cgroup v1, Docker 29.9.3 with a private containerd 2.4.2, `--containerd SOCK`, own namespace, vfs, no bridge): `kill -9` of containerd and a restart of it leaves `docker ps` Up and `docker exec` working (dockerd waits for containerd and re-attaches; the shims survive).
- The mismatch appears only when containerd's own records are destroyed by hand: `kill -9` containerd, delete `io.containerd.metadata.v1.bolt` and `io.containerd.runtime.v2.task`, restart containerd. Then `docker ps` stays Up and `docker exec` answers `NotFound: container "<id>" in namespace "<ns>": not found` (and it stays so after several seconds). The container process and its shim are still alive, unlike the thread ("no related processes"). This is a synthetic injection, which the screening note rules out (no editing of state to make the target output).
- A "recovery" oracle (restart, recreate, keep the volume) would be our own invention, not the thread's; the only answer is "upgrade".
- Coverage: q63457756 and q64401699 already cover dockerd/containerd/shim failures.

## If it is taken up later
Only as a synthetic variant stated as an adaptation (not the original incident): private containerd + dockerd as above, a workload with a named volume holding a marker; setup removes containerd's metadata as in the measurement; the oracle requires docker's status, the process and `docker exec` to agree again, the volume marker kept, and the container either restarted or recreated with the data intact (a recreate must be stated, not hidden). A stand-in that edits docker's own state files or prints a fake status must fail.
