# q75568311 — Kubernetes can't find locally built containerd images (compatibility)

Status: complete. Validated in the sandbox (containerd 2.2.3 and 1.7.28) and verified on the user's VM over several runs: only `reference_solution` and `alt_valid_stream_export_import` pass, the other 8 samples fail for the intended reason, and nothing is left behind afterwards (no `/run/bench75568311`, `/var/lib/bench75568311` or `/tmp/bench75568311`, no containerd shims).

## What the Stack Overflow thread is really about

The title and the suggested "namespace/import" idea point at an image-visibility problem, but the thread's own comments give a different root cause: the image was built on the control-plane node (it was already in the `k8s.io` namespace there, visible to both nerdctl and crictl), while the pod was scheduled to the *worker* node, whose containerd never had the image. With `imagePullPolicy: Never` the kubelet does not pull, so it fails with ErrImageNeverPull. Fix: save the image on one node and load it on the other (the asker did exactly that).

Consequence: modelling this case as "wrong namespace" would be a near-duplicate of q73420677. The cases test different things:

- q73420677: image is in the wrong namespace of the *same* daemon.
- q75568311: image is in the right namespace, but on the wrong *daemon* (node).
- q59161183: image is in a different *runtime's* store (Docker vs CRI-O).

## Scope decision

Kubernetes itself (scheduler, kubelet, API) is out of scope: there is no cluster. The mechanism underneath is not: per-node image stores, `ctr`/`crictl` addressing a specific containerd instance, and "CRI create never pulls" (the analog of `imagePullPolicy: Never`). That is the CRI/OCI runtime layer the benchmark targets, so the case is kept, but reproduced at the CRI level.

## Design

- Two private containerd daemons (`node-a` build node, `node-b` worker) started by `setup.sh`, each with its own root, state and socket under `/var/lib/bench75568311` and `/run/bench75568311`. The system containerd is not touched (no restarts, no rewritten config, no systemd start-limit exposure).
- Each daemon's config is `containerd config default` of the installed version, patched by a small script: private root/state/grpc/ttrpc paths, sandbox image pointed at a locally generated pause image (no registry needed at all), NRI disabled (it would listen on one shared socket), `restrict_oom_score_adj = true` (no CAP_SYS_RESOURCE needed).
- The application image is generated like in q73420677 (per-run token baked into a static binary, image ID = config digest) and imported into node-a's `k8s.io` only. Every other copy (tar, binary, generator) is deleted at the end of setup, so node-a's store is the only source.
- `/etc/crictl.yaml` is pointed at node-b and restored by `cleanup.sh` (the previous content is saved under `/var/lib/bench75568311`).
- Oracle checks: both nodes up; node-b's CRI lists the image with ID == recorded config digest; node-a still has it (copy, not move); node-b's *original* sandbox is the one in use; exactly one RUNNING container in it; created from that image; entrypoint `/bench-app` with a live process; log contains the per-run token.

## Samples (10) and what each one proves

| sample | expected | oracle branch it exercises |
|---|---|---|
| reference_solution | PASS | the whole chain |
| no_op_baseline | FAIL | check 2 (image absent on node-b) |
| naive_crictl_pull_from_registry | FAIL | check 2 (no registry has it) |
| wrong_runs_workload_on_node_a | FAIL | check 2; proves the oracle looks at node-b, not at "some container named like this" |
| wrong_import_node_b_default_namespace | FAIL | check 2 (right daemon, namespace its CRI never reads) |
| partial_image_copied_container_not_created | FAIL | check 5 (image visible but nothing running) |
| alt_valid_stream_export_import | PASS | export piped into import, no temp file |
| cheating_retag_other_image_same_name | FAIL | check 2 id mismatch (retagging the pause image) |
| wrong_recreates_pod_sandbox | FAIL | check 4 (sandbox recreated) |
| wrong_moves_image_deletes_from_node_a | FAIL | check 3 (node-a lost its image) |

## Findings worth keeping

1. `pkill -9 -f "<path>"` in a cleanup script kills any process whose command line merely mentions that path, including the shell that is running the user's own command. Match daemons and shims by process name first and then check their command line.
2. After `kill -9` of a daemon its shim and workload show up as zombies (state Z) for a moment; counting them with `pgrep` right away gives a false "still alive". They are reaped within seconds.
3. Samples that mention the case's run directory in their command line are harmless for the harness (the solution finishes before cleanup runs), but never run two case lifecycles concurrently against the same case directory.
