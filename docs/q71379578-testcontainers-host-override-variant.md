# q71379578 — Testcontainers in a pod on a containerd node (compatibility) — BUILT as a HOST_OVERRIDE variant

Status: built and closed on the VM (2026-11-18); replaces the earlier "deferred" note (2026-10-20). Case files: `cases/compatibility/q71379578/`, suite `src/test_suites/compatibility/q71379578.py`, samples `samples/fixtures/compatibility/q71379578.json` (10 samples: 2 pass, 8 fail).

## What the thread is about
A microservice's Testcontainers integration tests (Java, Kafka) ran on GKE with the Docker runtime. After the move to containerd (Kubernetes 1.23) they fail: `Can not connect to Ryuk at localhost:49153`; in a containerd-only Minikube: `Could not find a valid Docker environment`. The asker's own answer: set `TESTCONTAINERS_HOST_OVERRIDE` in the Pod (value `status.hostIP`); another answer: `TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal` and `TESTCONTAINERS_RYUK_DISABLED=true`. The original suite, the Pod manifest and the source of the Docker endpoint are not in the thread.

## Why this variant (scope decision)
The thread is near-identical to q72518766 (built) and q76980610 (deferred): all three need a Docker API on a containerd node. "Containerd only" has no proven reference (a bare containerd has no Docker API), and that part is already covered by q72518766. This case keeps only what is different: the Docker API exists, but Testcontainers in the pod looks for the mapped port at `localhost` (the pod's own loopback) while the port is published on the node. Fix: `TESTCONTAINERS_HOST_OVERRIDE=<node IP>` (status.hostIP) in the job's environment.

## Adaptation (labelled in task.txt and docs)
- No Kubernetes/Jenkins/kubelet. The thread does not say where the post-migration Docker API comes from, so the stand-in is the node's dockerd on the node's containerd, started by setup (stays; must not be restarted).
- "Node" = private mount namespace (tmpfs /run, /etc/docker, /etc/containerd) with containerd + dockerd, docker bridge `bench71br`, published ports by docker-proxy (`userland-proxy` true, no iptables).
- "Pod" = separate network namespace (holder + veth `vb71h` 10.66.71.1 / `vb71p` 10.66.71.2; node = default gateway). Wrappers: `node-run`, `pod-run`, `run-test`. The pod's `env:` is the file `home/job.env`.
- Ryuk and the disk check are switched off in the wrapper (their images cannot be pulled offline), as in the thread's second step.
- Testcontainers 1.21.4 / docker-java 3.4.2 pinned (Docker 29 refuses API 1.32; works with Docker 27 as well).

## Measured facts
- From a separate network namespace the container starts and then `Timed out waiting for container port to open (localhost ports: [N] should be listening)`; with `TESTCONTAINERS_HOST_OVERRIDE=<node IP>` the test gets the node IP from `getHost()` and an HTTP answer with the nonce.
- `TESTCONTAINERS_HOST_OVERRIDE` works only as an environment variable: `host.override` / `tc.host` in `~/.testcontainers.properties` are ignored.
- `host.docker.internal` does not resolve in the pod.
- An iptables DNAT of the pod's 127.0.0.1 to the node makes the test pass at host=localhost; the oracle rejects it (the address must be an address of the node, not 127.*/localhost; a docker-proxy of the node must hold the port).
- A Probe that calls `System.exit` inside try-with-resources leaves the container behind; the case's Probe exits after the block.
- Verified on the VM (Ubuntu 22.04 aarch64, cgroup v2, Docker 27.5.1): all 10 samples as expected, no residue.

## Not covered / still open
- A real Kubernetes pod/kubelet, Ryuk itself, the "containerd only, no Docker API" reference (see q72518766 for the stand-in dockerd on containerd), q76980610 (Docker Desktop variant) stays deferred.
