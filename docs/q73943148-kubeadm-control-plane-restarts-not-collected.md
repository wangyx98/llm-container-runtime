# q73943148 — containerd and kubernetes container will be down randomly (diagnostics) — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-19). Nothing was built (no case files, test suite, fixtures or docs-index entries).

Source: https://stackoverflow.com/questions/73943148/containerd-and-kubernetes-container-will-be-down-randomly

## What the thread is about
Debian, kubeadm with Kubernetes 1.25.1/1.25.2 images, containerd as the runtime. `crictl ps` shows the control plane containers with very high ATTEMPT counts (etcd 1876, apiserver 123, scheduler 132, controller-manager 124, kube-proxy 117) and containers that come and go between calls; when the apiserver is down `kubectl` is refused. The asker gives no exit codes, no `crictl inspect`, no kubelet or containerd journal, no OOM information, no containerd or kubelet configuration. There is no answer; four comments suggest generic checks (pod logs, `journalctl -xe`, kubeconfig setup).

## Reading (not evidence from the thread)
A common cause of this picture is a cgroup driver mismatch: kubeadm's kubelet uses the systemd driver, while containerd's generated default config has `SystemdCgroup = false`. Nothing in the thread confirms it.

## Why it was not collected
- No cause and no observable in the thread; the screening stop condition (lock one controlled cause first; "a few minutes without a restart" is not an oracle) is not met.
- Reproducing the symptom needs a real kubelet and a kubeadm control plane (kubelet/kubeadm binaries, etcd/apiserver images, ports, minutes of start-up on the shared VM). Without a kubelet any cgroup-driver fault would be our own construction and would not produce the restarts of the thread.
- Closest built case: q68845002 (systemd-style cgroup parent with a cgroupfs runc, cgroup v1 only). Closest not-collected notes: q54819127 and q52678769 (no runtime evidence).

## If it is taken up later
Only with container status and exit codes, the kubelet and containerd journals, the containerd `SystemdCgroup` setting and the kubelet `cgroupDriver`. An oracle would run a fixed control plane workload over several restart periods with the API available and the restart counters no longer growing, after fixing one stated cause (for example the matching cgroup driver on both sides); a single quiet observation would not pass.
