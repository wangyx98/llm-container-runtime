# q76632144 — NeuVector via Helm on local k3s: "Unknown container runtime" (compatibility) — DEFERRED

Status: deferred by the user (2026-10-20). Nothing was built.

## What the thread is about
NeuVector 5.0.4 (chart `neuvector/core` 2.2.4, `registry=docker.io`) on a local k3s with containerd. The controller logs `container.Connect: - endpoint=` (empty) and `Failed to initialize - error=Unknown container runtime`. The only answer: install with `--set k3s.enabled=true` (the chart then mounts k3s' containerd socket under /run/k3s/containerd and sets the runtime endpoint; NeuVector does not look there by itself). A comment adds that cgroup v2 was needed on the asker's machine.

## Why it was not built
- The sandbox cannot obtain the real tool: Docker Hub token host (auth.docker.io), ghcr.io, quay.io, neuvector.github.io and get.helm.sh are refused by the egress policy, so no NeuVector image or chart can be pulled or run there; only the k3s release on github.com is reachable. The screening condition ("NeuVector really discovers the container and its runtime; Pod Ready or a silent log is not enough") needs the real controller/enforcer, so a verified case cannot be produced here.
- The pinned version of the question (5.0.4) may not have arm64 images (not verified), and the VM is aarch64; a multi-arch NeuVector/chart combination would have to be chosen and checked on the VM.
- The user's own screening note: the endpoint diagnosis is already covered by earlier cases (generated config, CRI endpoint mismatch), the extra cost is tool integration; keep it as an endpoint-template variant only.

## If it is taken up later
Needs the sandbox egress opened for docker.io (auth.docker.io, registry-1.docker.io, production.cloudflare.docker.com), neuvector.github.io (or the chart release asset on github.com) and get.helm.sh, or a build done blind on the VM. Design sketch: real k3s on a private containerd (as q69088569), helm install with the asker's values minus `k3s.enabled`; precondition: controller exits with `Unknown container runtime` and the endpoint is empty; control: the same chart with `k3s.enabled=true` (or the socket mounted and the runtime endpoint set) discovers; oracle: NeuVector REST API lists the pinned test container and the runtime, a container started after the install is discovered too; samples: `k3s.enabled=true` (PASS), manual hostPath mount + endpoint env (alt), only Helm Ready checks, wrong socket path, docker socket path, no-op (FAIL).
