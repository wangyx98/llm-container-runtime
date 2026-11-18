# q72488021 — Back-off pulling image in Kubernetes (compatibility) — NOT COLLECTED

Status: assessed and not collected by the user (2026-11-17). Nothing was built (no case files, test suite, fixtures or docs-index entries). Reason: the full thread shows a root cause that existing cases already cover; no new runtime mechanism.

## What the thread is about
A Kubernetes cluster with containerd. The asker builds `app:latest` with `docker build` on a node and writes `image: app` in the Deployment. The pod fails with `ErrImagePull`: `failed to pull and unpack image "docker.io/library/app:latest": failed to resolve reference ...: pull access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed`. `ctr images ls` showed nothing at first; after `ctr images import` the image is listed, but the pod fails the same way. The only answer (by the asker, not accepted, one comment asking for more detail): import the image into the containerd namespace `k8s.io`; then the pod runs.

## Reading of the thread
- `ctr` works in the namespace `default` unless told otherwise; the kubelet's CRI only looks at `k8s.io`. The imported image is invisible to the kubelet, which then tries to pull `docker.io/library/app:latest` from Docker Hub and gets `pull access denied`. The ImagePullBackOff is a symptom; registry, authentication and TLS are not involved.
- The error text differs from the covered cases only because the pod has no `imagePullPolicy: Never`: the kubelet falls back to a pull instead of failing with `not found`.

## Why it was not collected
- Same mechanism as q73420677 (image loaded with `ctr` into `default`, CRI cannot find it, import into `k8s.io`), q78814823 (the reverse: CRI pulled it, `ctr` shows nothing in `default`) and, with the namespace ruled out, q74685092 (ctr and crictl talk to different daemons).
- The only new element is the wording `pull access denied ... insufficient_scope`. Reproducing it needs Docker Hub (not reachable from the sandbox: the token host is refused) or a stand-in registry that answers 401 `insufficient_scope`; that is a stand-in for an error message, not a different runtime cause. Cost about 2-3 hours (k3s or a CRI pod with a pull policy that pulls, plus the stand-in registry) for no new coverage.
- Not a Windows or arm64 restriction.

## If it is ever reconsidered
Only as a variant of q73420677 without `imagePullPolicy: Never`: private containerd with CRI, a pod config whose image name is not in `k8s.io` and a registry stand-in that returns `insufficient_scope`; oracle: the image is in `k8s.io` with the digest of the tar (not a retag), the pod runs and prints a per-run nonce, and the registry stand-in received no successful pull.
