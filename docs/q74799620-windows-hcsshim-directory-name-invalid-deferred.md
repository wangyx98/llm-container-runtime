# q74799620 — Kubernetes Windows worker node: `failed to create containerd task: hcsshim::CreateComputeSystem kube-proxy: The directory name is invalid` (compatibility) — DEFERRED

Status: analysed and deferred by the user (2026-11-19). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
Kubernetes 1.23.13 (Ubuntu 18 control plane on VMware ESXi, Flannel CNI, containerd) with a Windows Server 2019 worker added by the sig-windows guide (archived kubernetes.io "adding Windows nodes"). The node joins, but `kube-proxy-windows` is in CrashLoopBackOff and the Windows flannel daemonset in ImagePullBackOff. Event: image `sigwindowstools/kube-proxy:v1.23.13-nanoserver` is present; `Error: failed to create containerd task: hcsshim::CreateComputeSystem kube-proxy: The directory name is invalid. (extra info: {...})`. The JSON shows `containerd-shim-runhcs-v1.exe`, eleven layers below `C:\ProgramData\containerd\root\io.containerd.snapshotter.v1.windows\snapshots\9..19`, `MappedDirectories` (the host `c:\` as `c:\host`, kubelet pod directories for the termination log, the kube-proxy and kube-proxy-windows configmaps, the service-account projection and the etc-hosts file) and a mapped pipe `rancher_wins`. Answers: (1) a pointer to the sig-windows issue/guide and a troubleshooting blog for CrashLoopBackOff (no fix); (2) a user on k8s 1.24 had the same error with flannel; the cause was Windows patches not applied, KB4489899 is needed (link to the sig-windows "before you begin"). No answer is accepted; the asker never reports a result.

## Why it was deferred
- Windows-only: HCS (`CreateComputeSystem`), `containerd-shim-runhcs-v1`, the Windows snapshotter and a nanoserver image exist only on a Windows host. The sandbox is x86_64 Linux and the test VM is Ubuntu 22.04 aarch64; the project has no Windows runner of either ISA.
- No verifiable repair in the thread: the only concrete statement is an OS patch level (KB4489899) from a different k8s version and a different Windows build; the asker's own Windows build, patch level, containerd and sig-windows-tools versions are not given, so the trigger cannot be pinned.
- A Linux stand-in would lose the original fault (the screening note forbids switching to Linux or dropping the original path constraints).

## Coverage
No case covers hcsshim or a Windows container. Same reason as q66597987 (Windows named pipe, Go SDK) and q64667740 (ACI/LCOW), both deferred.

## If it is taken up later
Only with a Windows batch that has a runner: a pinned Windows Server build and patch level, containerd with `containerd-shim-runhcs-v1`, `sigwindowstools/kube-proxy:v1.23.13-nanoserver` (or another pinned nanoserver image) and the original mappings kept (host `c:\` as `c:\host`, kubelet pod volumes, `rancher_wins`). First establish a repeatable failure and a matching working combination (patch level, OS build, isolation, containerd/runhcs version) on that runner; then the task is to make the original workload create through hcsshim and print a per-run marker, repeatable from a cold start and after cleanup, without Linux or dropping the mapped paths. The five stages would need PowerShell variants (the harness is bash). Both x86_64 and arm64 Windows would be needed to keep the dual-ISA rule.
