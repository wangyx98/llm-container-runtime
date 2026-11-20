# q74526816 — HAproxy static pod runs 100% CPU on node on containerd (diagnostics) — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-19). Nothing was built (no case files, test suite, fixtures or docs-index entries).

Source: https://stackoverflow.com/questions/74526816/haproxy-static-pod-runs-100-cpu-on-node-on-containerd

## What the thread is about
Moving a Kubernetes node from dockershim to containerd, a static pod running HAProxy (version output 2.0.25, image tag written as `haproxy:v2.0.0`) uses 100% CPU; resource limits do not apply to the static pod; the same image under Podman, or under Docker as the engine, is fine. The pod spec in the question has no `volumeMounts` line for the hostPath config and the `haproxy.cfg` is not shown. The asker's own answer (not accepted): without `maxconn` in `global`, HAProxy derives it from the maximum number of open files, 536870882 on his node, which gave 100% CPU and 95% memory; `maxconn 10000` fixed it.

## Reading and measurement (2026-11-19, sandbox x86_64; HAProxy 2.8.30 from apt)
- The runtime link is the inherited `RLIMIT_NOFILE` (containerd's unit `LimitNOFILE=infinity` becomes `fs.nr_open` of the node); the failure itself is an application default.
- The sandbox cannot raise the hard limit above 20000 (no CAP_SYS_RESOURCE; `fs.nr_open` is 1048576), so a value near 5e8 could not be set. With no `maxconn`, HAProxy 2.8 RSS grows linearly with nofile, about 70 bytes per fd (15.1 MB at 2000, 16.5 MB at 20000), and uses no CPU when idle. By extrapolation the VM's default 1048576 would add about 70 MB; the thread's 95% memory needs `fs.nr_open` near 1e9 and tens of GB of RAM.
- HAProxy 2.0.25 was not obtained (apt has 2.8; Docker Hub is not reachable; a source build was not tried).

## Why it was not collected
- No stable bad/good pair that does not depend on exhausting the machine: the reachable nofile values give a small memory difference and no CPU symptom, and the thread's symptom needs a global sysctl change plus memory exhaustion on a shared VM.
- The cause is application sizing (`maxconn`), with the runtime only passing the limit on; the missing `haproxy.cfg` and pod-spec errors leave the original unclear.
- Screening note: lower priority than runtime metric/log cases.

## If it is taken up later
As a stated adaptation, not the thread's symptom: HAProxy 2.8 in a CRI pod with `rlimits` nofile 1048576 (VM root has CAP_SYS_RESOURCE), config without and with `maxconn`; oracle: the service answers a fixed request in both, RSS below a calibrated budget only with `maxconn`, the proxy not stopped to lower memory, the limit not lowered below the stated nofile. Full reproduction needs a dedicated runner with `fs.nr_open` near 1e9 and the pinned 2.0.25.
