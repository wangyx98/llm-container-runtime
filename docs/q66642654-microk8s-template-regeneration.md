# q66642654 — MicroK8s: ImagePullBackOff for a plain-HTTP local registry, the config edit has no effect (configuration)

Status: built and verified in the sandbox (x86_64, containerd 2.3.6, runc 1.5.1; root, non-root with sudo, pty, 3 repeats, oracle twice on one setup, clean residue). Also run in the sandbox with the release binaries of containerd 2.2.1 (the VM's version, config version 3): same results. First VM run (aarch64, cgroup v2) stopped at precondition control 1 because only one wording of the https error was accepted; fixed (both wordings).

## What the question is really about
The asker wrote a registry `mirrors` entry (http endpoint, insecure_skip_verify) into `/var/snap/microk8s/current/args/containerd.toml` and rebooted; the pull still went to https. MicroK8s does not keep that file: its launcher renders `args/containerd-template.toml` into `containerd.toml` at every start of containerd, so the edit is gone after the restart. The persistent place is the template (then a restart: containerd reads its configuration at start). The snippet of the question is also the containerd 1.x CRI plugin (`plugins.cri.registry`); a 2.x configuration reads the registry table under `io.containerd.cri.v1.images` (`mirrors`, deprecated, or `config_path` + hosts.toml).

## Model (modern adaptation, said so in task.txt)
Private containerd started by `mk8sctl start|stop|restart` through `mk8s-run-containerd` (renders the template with ${SNAP_DATA}/${SNAP_COMMON} at every start, writes a pid file, execs containerd). Plain-HTTP registry fixture at 10.66.64.45:32000 (a /32 alias of lo: loopback registries are plain HTTP by default). Pods are made with crictl (host network). The kubelet's pull is the CRI PullImage call.

## Oracle
Launcher, mk8sctl, registry process and address unchanged; the containerd that answers is the pid-file process with `--config containerd.toml`; containerd.toml equals the rendering of the template. Phase A (node as left) and phase B (after `mk8sctl restart`): registry images removed from the CRI store, a NEW build of myapp:latest pushed (new salt, new digests), CRI pull (image id, manifest + both blobs requested by `containerd/` in the registry log), a pod runs it (nonce + salt in the log, `/proc/PID/root/salt`).

## Samples (9)
reference_solution PASS (template + mirrors entry + restart); alt_valid_template_config_path_with_a_hosts_directory PASS; no_op_baseline FAIL; wrong_registry_entry_in_the_generated_containerd_toml_then_restart FAIL (the asker's try); wrong_template_edited_node_not_restarted FAIL; wrong_question_snippet_in_the_template_old_plugin_id FAIL; cheating_image_preloaded_with_ctr_plain_http FAIL; cheating_containerd_stopped_and_started_by_hand_with_an_edited_configuration FAIL; cheating_launcher_patched_to_append_the_entry_after_rendering FAIL.

## Findings
A pull over https to a plain-HTTP registry says `server gave HTTP response to HTTPS client` or `tls: first record does not look like a TLS handshake` depending on the Go version of the containerd build; accept both. containerd 2.3 config version 4 moves grpc/ttrpc/debug to `io.containerd.server.v1.*` (older patch_config copies miss it and land on the host's socket); `mirrors` and `config_path` both work for the CRI on 2.3.6; no sample fails only in phase B (a second guard); host-network pods must not set `hostname`.
