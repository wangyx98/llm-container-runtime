# q69088569 — MicroK8s: pushed image to the local registry, pod can't pull it (compatibility)

Status: complete. Validated in the sandbox (x86_64, containerd 2.2.3, k3s v1.30.5+k3s1, as root and as an unprivileged user with sudo) and on the user's VM (aarch64, containerd 2.2.1): `reference_solution` and the three `alt_valid_*` samples pass, the other 8 samples fail for the intended reason, nothing is left behind afterwards.

## What the Stack Overflow thread is really about

Three separate problems are tangled in the question and its answers:

1. **The name.** `kubectl create deployment argus --image=argus` asks for `docker.io/library/argus:latest`, not for the image the asker pushed to `localhost:32000`. Fix: use the registry name, with the tag that was pushed (`:registry`, not `:latest`).
2. **The protocol.** The registry speaks plain HTTP; `ctr images pull localhost:32000/...` talks HTTPS and fails ("server gave HTTP response to HTTPS client"; newer ctr: "tls: first record does not look like a TLS handshake"). The accepted answer's fix for `ctr` is `--plain-http`.
3. **The client.** `ctr` and the kubelet's CRI are different clients with different configuration entries: ctr takes a flag per call (or `--hosts-dir`), the CRI plugin reads the registry configuration directory named by `config_path` in containerd's config (not `ctr`'s flags, not the old `mirrors` table), and the two use different namespaces (`default` for ctr, `k8s.io` for the CRI). The asker had configured the mirror and still saw ctr fail.

(A fourth, minor point in the answer: an image whose main process exits ends in CrashLoopBackOff. The case's image never exits, so this does not interfere.)

## Scope decision

MicroK8s is a snap and cannot be reproduced in a sandbox or in a plain VM without it. What matters for the benchmark is the mechanism underneath: a Kubernetes node whose runtime is containerd, a plain-HTTP registry, and the CRI pull path. So the case uses **real k3s on a private containerd** (k3s' `container-runtime-endpoint`, the scaffold of q71572715) and a `mk8s` wrapper that offers `mk8s kubectl ...` and `mk8s ctr ...` like `microk8s kubectl` / `microk8s ctr` (ctr keeps its own default namespace `default`). The task text says plainly that it is "a single-node Kubernetes on a containerd of its own".

## Design

- `setup.sh` builds two Docker-format images offline with `gcc -static`: ARGUS (prints a per-run token every 5 s, never exits) and the pods' sandbox image (nothing to download, no registry needed). ARGUS is pushed with the plain distribution API (`POST ...?digest=` per blob, `PUT` manifest), the way `docker push` does; the build inputs are deleted afterwards.
- The registry is the mini registry of q64513122 (plain HTTP on 127.0.0.1:32000, request log with status and User-Agent, `state.json`), with the organisation policy switched off. Port 32000 is the MicroK8s port; setup refuses to run when something already listens on it.
- The private containerd uses `containerd config default` patched by a small script: private root/state/sockets, NRI off, the sandbox image, the CNI directories, and **`config_path = ''` forced for the CRI registry section** (the default differs between containerd versions: on the user's 2.2.1 it was not empty and the first precondition failed).
- k3s runs with the same minimal footprint as q71572715 (no add-ons, no kube-proxy, no flannel) and `container-runtime-endpoint` pointing at the private containerd. The deployment is created by setup exactly as the asker did, and setup waits for ErrImagePull.
- Oracle (all dynamic): (1) the registry is still the process of setup, `state.json` is byte-identical, the request log has no write; (2) k3s on this containerd, node Ready (polled: the node status is stale or "Unknown" for a few seconds after a containerd/k3s restart); (3) a pod of the deployment is Running+Ready, 0 restarts, its imageID is the manifest digest **or** the config digest of the registry's image, and it asks for `localhost:32000/argus:registry` (or 127.0.0.1); (4) its log carries the image's token and it still runs 6 s later; (5) the registry log shows containerd fetching the manifest and both blobs; (6) the image is removed from `k8s.io` and `crictl pull` (the CRI call of the kubelet) pulls it again from the registry with the same digest.

## Samples (12) and what each one proves

| sample | expected | oracle branch it exercises |
|---|---|---|
| reference_solution | PASS | the whole chain: hosts.toml + `config_path` + containerd restart + `set image` |
| alt_valid_127_host | PASS | same under `127.0.0.1:32000` |
| alt_valid_recreate_deployment | PASS | delete and recreate the deployment instead of `set image` |
| alt_valid_certs_dir_in_lib | PASS | registry config dir somewhere else than `/etc/containerd/certs.d` |
| so_answer_ctr_plain_http_only | FAIL | check 6: the accepted SO route (ctr `--plain-http` pre-pull + full name) runs the pod but leaves the CRI unable to pull |
| naive_full_name_only | FAIL | check 3: the CRI still talks HTTPS |
| naive_hosts_toml_without_config_path | FAIL | check 3: `hosts.toml` is never read without `config_path` |
| naive_config_path_without_hosts | FAIL | check 3: nothing says the registry is HTTP |
| naive_latest_tag | FAIL | check 3: `localhost:32000/argus` is `:latest`, the registry has only `:registry` |
| naive_https_server_in_hosts | FAIL | check 3: wrong scheme |
| naive_retag_as_docker_io | FAIL | check 3: pod runs from a local re-tag under the name `argus`, not the registry's name |
| no_op_baseline | FAIL | check 3 |

## Findings worth keeping

1. **imagePullPolicy is Always.** `create deployment --image=argus` has no tag, so the API server defaults the policy to Always at creation; `set image` later does not change it. A pre-pulled image therefore does not help: the kubelet asks the registry every time. This is why the ctr-only route fails the case, and it is the realistic reason the asker kept seeing pull errors.
2. **The CRI always adds a `loopback` CNI plugin**, and go-cni needs the result to contain an interface named like the pod's (`eth0`). A pods-need-no-network node still needs two stub plugins (`loopback`, `benchnet`) that answer CNI; with an empty result the sandbox fails with "failed to find network info for sandbox".
3. **containerd 2.x refuses `cni.bin_dir` and `cni.bin_dirs` together**; the default config has `bin_dirs` and an empty `bin_dir`, so the patch script must only touch `bin_dir` when it is not empty.
4. **`/run` is mounted `noexec` on Ubuntu**: the control scripts (`k3sctl`, `containerdctl`, `mk8s`) live in `/var/lib/bench69088569/bin`, not in `/run`.
5. **imageID has two forms.** For an image pulled by the CRI the pod reports `localhost:32000/argus@sha256:<manifest digest>`; for an image pre-pulled by ctr it reports the config digest. Both identify the pushed image; the oracle accepts both.
6. **Fixed host paths owned by the case.** Like q71572715, k3s writes `/etc/rancher`, `/var/lib/kubelet`, `/run/k3s` (removed only when setup left its ownership marker); the kubelet also leaves empty `/var/log/pods` and `/var/log/containers`, which setup tolerates when empty. The registry configuration a solution writes under `/etc/containerd/certs.d/{localhost:32000,127.0.0.1:32000,...}` is removed by cleanup, and setup refuses to start when such a directory pre-exists.
7. **k3s download.** Not installed → downloaded from the k3s release page, sha256 pinned for x86_64 and aarch64. A non-root user in the sandbox cannot read the proxy's CA bundle, so unprivileged sandbox runs use `BENCH69088569_K3S_BIN`.

## Known limits

- Verified on containerd 2.2.x only. The reference solution edits the section `[plugins.'io.containerd.cri.v1.images'.registry]`; on containerd 1.x the section is `[plugins."io.containerd.grpc.v1.cri".registry]` (the patch script of setup.sh is written for both layouts but was not run on 1.x; the reference solution only knows the 2.x one).
- The Docker side of the question (`docker push`/`docker images`) is mimicked by the push in setup, not exercised.
- Every pod gets the same fake address from the stub CNI; nothing in the case needs pod networking.
- A full run of the 12 samples takes about 20 minutes (a failing sample waits up to 110 s for the pod); valid samples take 40–60 s.
