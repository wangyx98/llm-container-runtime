# q74417278 — Trivy on EKS unable to scan any images (Bottlerocket, trivy-operator) (compatibility) — DEFERRED

Status: analysed and deferred by the user (2026-11-17). Nothing was built (no case files, test suite, fixtures or docs-index entries). The Trivy source was read; no Trivy binary could be run (see "Why it was deferred").

## What the thread is about
EKS 1.23, all worker nodes Bottlerocket, trivy-operator Helm chart 0.6.0-rc3. The `scan-vulnerabilityreport` jobs start and exit at once. Trivy's FATAL line is `unable to initialize a docker scanner: 4 errors occurred`:
1. `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`
2. `unable to initialize Podman client: no podman socket found`
3. `containerd socket not found: /run/containerd/containerd.sock`
4. `GET https://<acct>.dkr.ecr.us-gov-east-1.amazonaws.com/v2/docker.io/istio/pilot/manifests/1.15.2: unexpected status code 401 Unauthorized`

The asker set `CONTAINER_RUNTIME_ENDPOINT=/run/containerd/containerd.sock` on the operator, mounted the socket into the pod and added a container-level `seLinuxOptions` (`system_u:system_r:control_t:s0-s0:c0.c1023`): same error. Comments: works on a local K3s and on other EKS clusters. The only answer is the asker's own (not accepted): the messages are misleading, it was an authentication problem with ECR; the SELinux options have to be set at pod level, not container level; mounting the docker/containerd socket was not necessary.

## What was established (2026-11-17)
- Trivy source at v0.34.0 (the period of that operator chart; `pkg/fanal/image/daemon/containerd.go`, `pkg/fanal/image/image.go`): the image is looked up through docker, podman, containerd and finally the remote registry; every failure is appended to one `multierror`, which is the 4-error message above. The first three are fallbacks, not the cause; whether a scan can work is decided by the last one (registry auth) when no runtime socket is usable.
- Containerd settings of Trivy: address from **`CONTAINERD_ADDRESS`** (default `/run/containerd/containerd.sock`), namespace from **`CONTAINERD_NAMESPACE`** (default **`default`**, not `k8s.io`). `CONTAINER_RUNTIME_ENDPOINT` is crictl's variable and Trivy never reads it, so the asker's setting could not change the path in message 3. In a pod the socket must be mounted AND the namespace must be `k8s.io` to see Kubernetes' images.
- The root cause reported by the asker (ECR 401, i.e. no registry credentials for the private ECR; SELinux label at pod level on Bottlerocket) is at the cloud/cluster layer, not the container runtime.

## Why it was deferred
- Not runnable in the sandbox: `github.com/aquasecurity/trivy` (release assets 404, repo page and codeload 403), `ghcr.io` (the vulnerability DB `ghcr.io/aquasecurity/trivy-db`), `get.trivy.dev`, the Aqua apt repo and the Go proxy are all refused; only `raw.githubusercontent.com` (source text) works. So no Trivy behaviour could be measured here, and a case would run for the first time on the VM.
- Coverage: the part that touches a runtime (socket address and namespace of a containerd client) overlaps q73420677, q78814823, q76534717 and q74685092; registry 401 chains are in q69088569 / q64513122 and in the faasd note q64540738. The new increment is only "the scanner's own client settings", while the thread's cause (ECR auth, pod-level securityContext on Bottlerocket) cannot be reproduced on Linux.
- A success of the scan must not be read as a runtime fix.

## If it is taken up later (as an adaptation: standalone CLI, not the operator)
Needs a host where the Trivy release (pin version and sha256 for amd64/arm64) is downloadable, and an offline way to give Trivy a database or to run without one (SBOM/package list only). Design: private containerd + an offline image with a known package database (e.g. `/lib/apk/db/installed` + `/etc/os-release`) in namespace `k8s.io`; optionally a mini registry that answers 401. Bad state: the scan with only a wrong env var (`CONTAINER_RUNTIME_ENDPOINT`) or the default namespace fails with the thread's fallback chain (socket not found / image not found / 401). Reference: `CONTAINERD_ADDRESS` and `CONTAINERD_NAMESPACE=k8s.io`, or registry credentials. Oracle: the scan's report is produced by that entry point for the image digest and contains the preset package names/versions; re-scan a NEW image (new package versions) to defeat stored reports; the report must not be created empty; no use of the real live vulnerability counts as the only check. Marked as an adaptation in task.txt (no EKS, Bottlerocket or operator).
