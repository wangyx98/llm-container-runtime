# q68845002 — Ehcache "host only contains 0B of physical memory" under containerd (compatibility, cgroup v1 ONLY)

Status: built and verified in the sandbox (x86_64, cgroup v1, containerd 2.3.6, runc 1.5.1, docker 29.8.2; root, non-root `bench`, pty, repeated oracle, residue clean). On a cgroup v2 host (the user's Ubuntu 22.04 VM boots v2) the defect cannot appear: `setup.sh` prints `NOT APPLICABLE` and exits 1; runs on cgroup v2 machines (the aarch64 VM, the MacBook) should exclude the case. Not architecture-specific: pure Java, JDKs pinned for x86_64 and aarch64.

## What the thread is really about

The question has no verified answer. The asker's own workaround was `-XX:-UseContainerSupport`; an answer says a newer JDK 11 helps; Ehcache issue 2934 only suspects JDK-8226575. The cause, locked by experiments and the JDK sources:

1. Ehcache's off-heap code (`PhysicalMemory`) calls `OperatingSystemMXBean.getTotalPhysicalMemorySize()`; 0 gives "the host only contains 0B".
2. JDK 11.0.9 to 11.0.12 (container-aware bean) returns the container memory limit when it is `>= 0`, and the cgroup v1 code returns 0 when `memory.limit_in_bytes` cannot be read.
3. Those JDKs split each line of `/proc/self/cgroup` with `split(":")`: a cgroup path with a colon is cut, the memory controller's path stays unset, the file is not found → limit 0 (JDK-8272124, "cgroup path contains colon", fixed in 11.0.13, 8u312, 17.0.1). JDK 11.0.8 returns the host memory (no `>= 0` rule yet).
4. containerd's CRI plugin names the cgroup `<parent>.slice:cri-containerd:<id>` when the pod's parent is a systemd-style slice (a kubelet with the systemd cgroup driver); runc on cgroupfs (`SystemdCgroup = false`, the default) takes that string as a literal directory name WITH colons. Docker's path (`/docker/<id>`) has none.

Verified by controls that change one thing each (precondition.sh): JDK 11.0.13 on the same colon path works; JDK 11.0.9 on a cgroupfs-style parent works; the same image on a private Docker daemon works; `-XX:-UseContainerSupport` starts the cache but the JVM sees the host's memory (not accepted: the oracle wants total = the container limit).

## Design

- `setup.sh`: cgroup v1 gate; pinned Temurin 11.0.9 and 11.0.13 and Ehcache 3.9.3 / slf4j (sha256, cached in `/var/cache/bench68845002`, kept by cleanup); a 50 MB off-heap `CacheInit` program; two jlink runtimes in two offline docker archives (`cache-app:jdk11.0.9`, `:jdk11.0.13`, same program) and a static pause image; a private containerd (CRI on, runc on cgroupfs) started by `cachenodectl`; `run-workload` applies `workload/pod.json` and `container.json` through crictl (like a kubelet); first run prints the real exception.
- `oracle.sh`: scripts as recorded; pod.json changed only in `cgroup_parent`; container.json only in the image, which must be one of the two image ids; then twice (after `cachenodectl restart`): exit 0, `cache-ok nonce=…`, JVM total = limit = 536870912, no JVM options or option variables.

## Samples (7)

| sample | expected | where it fails / what it exercises |
|---|---|---|
| reference_solution | PASS | pod's cgroup parent made cgroupfs-style |
| alt_valid_image_with_jdk_11_0_13 | PASS | image with the fixed JDK |
| no_op_baseline | FAIL | the 0B error again |
| wrong_disable_container_support_of_the_jvm | FAIL | container environment changed |
| wrong_pod_parent_in_another_slice | FAIL | still a colon: 0B |
| wrong_image_that_is_not_on_the_node | FAIL | image id not allowed |
| cheating_run_workload_prints_a_good_result | FAIL | script hash differs |

## To run it on the VM

Needs cgroup v1 (hybrid): Ubuntu 22.04 with `systemd.unified_cgroup_hierarchy=0` on the kernel command line (GRUB, reboot). Without it the case is skipped as NOT APPLICABLE. First run downloads about 380 MB.

## Findings worth keeping

1. A JDK bug can look like a runtime bug: compare the cgroup path the runtimes create (`/proc/self/cgroup`), not only the limit.
2. `sudo` drops the proxy variables: use `sudo -E curl` for downloads.
3. `crictl` prints config-file warnings unless given `--config`; the container log file of a CRI container is shared by pods with the same log path: truncate it before `start`.
4. In a cgroup hierarchy `find -empty` never matches (control files), use `rmdir`.
