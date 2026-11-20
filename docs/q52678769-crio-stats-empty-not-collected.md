# q52678769 — Problem getting pods stats from kubelet and cri-o (diagnostics) — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-19). Nothing was built (no case files, test suite, fixtures or docs-index entries).

Source: https://stackoverflow.com/questions/52678769/problem-getting-pods-stats-from-kubelet-and-cri-o

## What the thread is about
On-premise Kubernetes 1.11.3, CRI-O 1.11.6, CentOS 7 with UEK 4.14.35. `crictl stats` returns an empty list and the kubelet's `stats/summary` (`curl localhost:10255/stats/summary`) has an empty `pods` array, while pods start and stop normally and the kubelet's node statistics exist; HPA does not work. Comments: `crictl info` shows RuntimeReady and NetworkReady true; no kubelet log, no CRI-O configuration, no cgroup driver. The only answer (not accepted): check the kubelet's health and logs, or use metrics-server. No root cause.

## Pre-study (sandbox x86_64, cgroup v1, CRI-O 1.34.0 + crictl 1.34.0, time-boxed)
- A pod with one container made through crictl: `crictl stats`, `stats -a` and `stats -o json` list the container with CPU, memory, disk and inodes at once, no configuration. `crictl statsp` printed only the header for that host-network pod (pod-level stats), which is not the thread's symptom.
- No natural trigger for an empty container-stats list was found; the only ways found are artificial (cut the socket, change the cgroup driver), which the screening note forbids as a stand-in for the original fault.

## Why it was not collected
- No cause in the thread; the stop condition (a failed store/workload and a minimal trigger) is not met.
- The original stack (CRI-O 1.11, kubelet 1.11, UEK 4.14, kubelet summary through cadvisor) cannot be run on the x86_64 + arm64 batch: CRI-O 1.11 has no arm64 build, and the summary needs a real kubelet.
- With current CRI-O the statistics chain works by default, so a case would be our own fault design, not the thread's cause.
- metrics-server (the answer) does not show that CRI stats are fixed, so it is not a reference solution.
- Coverage: the only close case is q63132692 (gVisor pods report no CPU, cause known: runsc release before 20210208, cgroup v1 only).

## If it is taken up later
Only with the kubelet log, the CRI-O configuration (cgroup manager and parent) and a stats path that returns nothing for a known running container. An oracle would compare the container's CRI stats with its cgroup counters (CPU usage growing under a controlled load) and, with a kubelet, the summary entry of the pod; an empty list must never be accepted as success.
