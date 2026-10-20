# q71379578 — Testcontainers on a containerd-only Kubernetes node (compatibility) — DEFERRED

Status: deferred by the user (2026-10-20). Nothing was built.

## What the thread is about
A microservice's Testcontainers integration tests (Java, Kafka) ran on GKE with the Docker runtime. After the move to containerd (Kubernetes 1.23) they fail: `Can not connect to Ryuk at localhost:49153`; in a containerd-only Minikube: `Could not find a valid Docker environment`. The asker's own answer: set `TESTCONTAINERS_HOST_OVERRIDE` in the Pod (value `status.hostIP`); another answer: `TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal` and `TESTCONTAINERS_RYUK_DISABLED=true`. The original suite, the Pod manifest and the source of the Docker endpoint are not in the thread.

## Why it was deferred
- Testcontainers speaks the Docker API; a bare containerd has no such endpoint, so there is no proven reference solution for "containerd only"; the acceptance must not be lowered to "a socket can be connected". A solution needs an allowed Docker-API-compatible backend (private dockerd, or `podman system service`), which the user had not yet decided.
- Low coverage: screening note says it overlaps 76980610/72518766 ("at most one of the three near-identical tasks"); those cases are not in the repo.
- The original test suite is not available, so a minimal own Java Testcontainers test would stand in for it; the Kubernetes Pod part would be dropped (host level only). The VM probably has no Java/Maven (setup would install them and download jars; not verifiable beforehand).

## Feasibility facts measured (sandbox, 2026-10-20)
Java and Maven exist; Maven Central is reachable through `repo1.maven.org` (not `repo.maven.apache.org`); pypi.org was not resolvable (no Python Testcontainers); docker 29.8.2 and podman 4.9.5 are installed; a test image can be built offline with gcc as in earlier cases (Ryuk disabled, so no Docker Hub image is needed).

## If it is taken up later
Design sketch: private containerd + a Testcontainers JUnit test as the only client; precondition: the test fails with "Could not find a valid Docker environment", a temporary Docker API backend makes the same test pass; oracle judges the protocol (`/version`, `/containers/json`), that the container was created through the allowed backend, port mapping, a nonce in the log, and cleanup; samples: reference (backend + DOCKER_HOST), alt backend (the other one), env vars only, socket path without protocol, Ryuk off only, fake socket, no-op.
