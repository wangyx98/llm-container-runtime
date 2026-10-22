# q63132692 — gVisor (runsc) pods report no CPU in CRI/metrics (diagnostics, cgroup v1 ONLY)

Status: built and verified in the sandbox (x86_64, cgroup v1 hybrid, containerd 2.3.6, runc 1.5.1): 14 samples as expected, residue clean. On a cgroup v2 host (the user's Ubuntu 22.04 aarch64 VM boots v2) `setup.sh` prints `NOT APPLICABLE` and exits 1; leave the case out of runs on v2 machines. The v2 gate was added after the VM run failed at the first gVisor pod.

## Why v1 only

The symptom needs a gVisor release before 20210208.0 (`runsc events --stats` has no CPU). Those releases know only cgroup v1: runsc creates `/sys/fs/cgroup/cpu/<cgroup_parent>/<id>` and opens `cpu.shares` with O_CREATE. On a v2 host that file does not exist and the open fails with `configuring cgroup: open /sys/fs/cgroup/cpu/bench63132692/<id>/cpu.shares: permission denied`. gVisor's systemd cgroup v2 support arrived in 2022-03, after the CPU export, so no release both runs on v2 and lacks the CPU; containerd 2.x has no `disable_cgroup`. So there is no v2 variant of this symptom (an ctr-level redesign that bypasses the CRI cgroup path was considered and not chosen).

## Design (short)

Private containerd (CRI, handlers runc and runsc) with three pods: `gv-busy`, `gv-idle` (runsc 20210125.0), `rc-busy` (runc control). gVisor releases pinned by sha512 (x86_64 and aarch64) in `/var/cache/bench63132692`. Fix: switch to a release that exports the CPU (20230306.0 or 20260105.0) and recreate the gVisor pods. The oracle rejects 20210208.0, which reports a counter that is not the pod's own (2.5–7.5 core/s for a busy pod).

## To run it on the VM

Boot cgroup v1 (hybrid): `systemd.unified_cgroup_hierarchy=0` on the kernel command line (GRUB, reboot), as for q68845002.

## Findings worth keeping

1. A newer runsc cannot read the state of sandboxes made by an older one (`stopp` fails with `json: cannot unmarshal number`): remove the old pods BEFORE switching the runsc link.
2. The runsc shim finds `runsc` through the PATH of containerd at each pod start, so no restart is needed.
3. Without CAP_SYS_RESOURCE the shim fails to set its OOM score (-999); setup patches only the node's copy of the shim when needed.
4. A new runsc with host network cannot report events; `network = "none"` in runsc.toml.
