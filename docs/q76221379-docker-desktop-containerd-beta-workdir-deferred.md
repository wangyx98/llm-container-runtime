# q76221379 — Docker build with WORKDIR makes Docker unable to find the image locally with Containerd beta enabled (compatibility) — DEFERRED

Status: analysed and deferred by the user (2026-11-18). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
Docker Desktop for Mac (macOS 12.4, `docker --version` 20.10.22) with the experimental "Containerd" option enabled. A minimal Dockerfile, `FROM rockylinux:9` + `WORKDIR /opt/deploy`, builds fine (`docker build --platform linux/amd64 -t minimal:test .`, BuildKit) and the image is listed by `docker image ls` and can be removed, but `docker run --rm --platform linux/amd64 -it minimal:test` fails: `Unable to find image 'minimal:test' locally` and `failed to resolve reference "docker.io/library/minimal:test": pull access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed`. Without the WORKDIR line (an image identical to the base) it works. The only answer, by the asker (empirical, no authoritative source; a comment asks for one and gets none): a bug in Docker Desktop's experimental "Containerd" option, possibly related to lazy-loading of images; disabling the option and restarting the daemon fixed it.

## Why it was deferred
- The failure belongs to one historic Docker Desktop for Mac beta build. There is no old Desktop snapshot or artifact to pin, and the thread's "fix" is to switch the option off: no operation target a precondition and an oracle could check.
- Sandbox probe (2026-11-18, x86_64, Docker 29.9.3, containerd 2.4.2): a private dockerd with `--feature containerd-snapshotter=true` (containerd image store, `docker info` driver type `io.containerd.snapshotter.v1`), an offline base made with `docker import`, `FROM base` + `WORKDIR /opt/deploy`, `docker build --platform linux/amd64`: the build succeeds and `docker run --platform linux/amd64` finds and starts the image; no "Unable to find image", no pull attempt. So a modern engine's containerd image store does not show the bug; it cannot be reproduced on Linux.
- Making it fail on a modern engine would need us to damage the image store by hand: a different fault, not the thread's. Not a Windows or arm64 limit; the missing piece is the old Mac/Desktop environment.

## Coverage
No case tests "build succeeds, image listed, run cannot find it" with a Docker image store. Close in symptom but different in mechanism: q72488021 (ctr namespace: image in `default`, CRI wants `k8s.io`; not collected), q73420677 (same namespace mechanism, built), q75568311 (image on the wrong node's store, built), q59161183 (image in another runtime's store, built).

## If it is taken up later
Only with a pinned old Docker Desktop for Mac (4.x with the containerd beta, Apple Silicon or Intel) or another way to get that exact engine build running per sample. Then: minimal Dockerfile with and without WORKDIR as the control, `--platform linux/amd64`, offline run of the built image (directory and content correct), no registry named like the image reachable and no automatic re-pull; the fix must not remove WORKDIR or change the host platform. Do not substitute a naming error or a hand-damaged image store.
