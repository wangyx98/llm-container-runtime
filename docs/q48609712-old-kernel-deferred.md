# q48609712 — Docker CE 17.12 on Ubuntu 14.04: "Failed to connect to containerd: failed to dial" (compatibility) — DEFERRED

Status: deferred by the user (2026-10-23). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
Docker CE installed from the official repository on Ubuntu 14.04; dockerd runs, `docker ps` says it cannot connect to the daemon. The upstart log shows `Failed to connect to containerd: failed to dial "/var/run/docker/containerd/docker-containerd.sock": ... timeout` and, from the containerd (v1.0.0) that dockerd starts, `setting subreaper... containerd: invalid argument`, then `containerd did not exit successfully`. Both answers: the kernel is too old (3.2; Docker needs 3.10 or newer); the asker installed a newer `linux-image` package, rebooted into 3.19 and it worked.

## Mechanism
containerd calls `prctl(PR_SET_CHILD_SUBREAPER)` at start. The option does not exist before kernel 3.4 and the call returns EINVAL, so containerd exits at once and dockerd only sees a socket that never appears (the "timeout"). It is a missing kernel capability, not a configuration problem.

## Why it was not built
- The symptom needs a real old kernel (< 3.4). The VM is Ubuntu 22.04 (kernel 5.15+, cgroup v2) and the sandbox is a cloud container; neither can boot a 3.2 kernel. A seccomp filter that makes only that prctl return EINVAL would reproduce the errno, but it is a simulation, and the screening note forbids simulating the kernel failure (also: "do not replace it by a unix-socket timeout").
- The fix (upgrade the kernel and reboot) cannot be part of an oracle on a single-kernel machine; with a seccomp stand-in the only "fix" is removing the filter, which teaches nothing about the question.
- Docker 17.12 with containerd 1.0.0 and the runc of that time do not run containers on a cgroup v2 host, so even the good control (a supported kernel where the workload runs) could not be built on the VM without switching it to cgroup v1 (as for q68845002 / q63132692).
- No two-kernel VM images or runner exist in the project; every case so far runs a private containerd node on the host's kernel.
- Coverage: q63457756 (docker cannot talk to containerd because the shim dies) and q64401699 (CRI recovery failure) already cover "daemon does not come up" diagnostics; the new element here is only the kernel-version threshold.

## If it is taken up later
Needs two bootable kernels on one disk or two VM images: a bad one (kernel < 3.4, e.g. a 3.2 distribution kernel) and a good one (3.10 or newer, ideally 3.19 as in the thread), Docker 17.12 static packages (docker, docker-containerd 1.0.0, docker-runc), cgroup v1. Bad control: save the prctl errno (strace or the containerd log line) and the dockerd log. Oracle after the switch and reboot: the correct socket exists, dockerd starts, a workload runs, images and data are kept; a stand-in that only makes the socket answer must not pass.
