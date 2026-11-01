# q78668565 — "Passing through /dev/mem into gVisor container" (isolation) — NOT COLLECTED (skip)

Status: classified skip by the user and confirmed after a feasibility check (2026-11-01). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
With Docker's default runtime (runc) `/dev/mem` is not in the container; `--device /dev/mem:/dev/mem` makes it visible, but reading fails with `Operation not permitted` until `--cap-add CAP_SYS_RAWIO` is added, after which reading works. With gVisor (Docker + runsc) `--device /dev/mem:/dev/mem` makes reading fail with `No such device or address` (ENXIO) and adding CAP_SYS_RAWIO changes nothing. The asker wants to know which additional mechanism in gVisor blocks the read and whether it can be enabled. The page has only the question: no answer, no comment, so there is no reference solution and no stated success contract.

## Measured / checked on 2026-11-01
- The sandbox kernel (x86_64, 6.18) is built without `/dev/mem` (`# CONFIG_DEVMEM is not set`, `STRICT_DEVMEM` not set). A host character node made with `mknod c 1 1` fails to open on the HOST itself with errno 6 (ENXIO, "No such device or address"), i.e. the very error of the gVisor case. In the sandbox the difference between runc and runsc therefore cannot be observed at all.
- Not measured: the user's VM (Ubuntu 22.04, aarch64, kernel 5.15). Distribution kernels normally set `CONFIG_STRICT_DEVMEM=y`, which limits what `/dev/mem` may read even to a privileged runc container, so "runc can read it" is not guaranteed there either.
- runsc is available for x86_64 in the sandbox cache (`/var/cache/bench63132692`: releases 20210125.0 to 20260105.0, pinned by sha512 in that case); no aarch64 build is cached or tested.
- The reason gVisor answers ENXIO (the sentry does not implement host device passthrough for generic character devices, with special proxies such as nvproxy for chosen devices) is an inference, not confirmed in gVisor's documentation or source here.

## Why it was not collected
- No supported passthrough exists to use as a reference solution and the thread states no success condition; the original ask (a successful read of physical memory) has no known fix to verify.
- gVisor's device support is not "a runc node plus a capability": a diagnostic variant (pin a runsc release/platform, positive control with a device gVisor does support, errno observation for `/dev/mem`) would assert only that this version refuses the device. That is the opposite of the question's goal, and a failed read says nothing about the sandbox's security as a whole.
- Real physical-memory reads depend on the host kernel's `CONFIG_DEVMEM`/`STRICT_DEVMEM`; a pseudo-file stand-in is excluded, and the sandbox kernel has no `/dev/mem` at all.
- Coverage: gVisor appears only in q63132692 (CPU statistics, cgroup v1 only, built) and q72555998 (minikube addon, deferred); device nodes without `--privileged` on runc are in q75294704. The gVisor device-support matrix is untested, but the thread gives no way to turn it into a verifiable task.

## If it is taken up later
Only as an explicit compatibility diagnostic, after running on the VM: record `CONFIG_DEVMEM`/`STRICT_DEVMEM` and the runc result with and without CAP_SYS_RAWIO on a node that really has `/dev/mem`; pin runsc (per-arch sha512) and the platform (systrap/KVM); positive control with a device gVisor supports; for `/dev/mem` compare the errno on runc and runsc. The task would ask for an observed fact about that version, not for a successful read, and the oracle must not treat one failed read as proof of isolation.
