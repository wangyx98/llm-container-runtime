#!/bin/bash
# Reference solution of q66512464: tell the kubelet to use containerd's CRI directly (flags of kubeadm-flags.env: --container-runtime=remote and the CRI socket), restart only the kubelet.
set -e
L=/var/lib/bench66512464
R=/run/bench66512464
sudo sed -i "s#--container-runtime-endpoint=unix://$R/dockershim.sock#--container-runtime=remote --container-runtime-endpoint=unix://$R/containerd.sock#" "$L/kubelet/kubeadm-flags.env"
grep -o -e '--container-runtime[^ ]*' "$L/kubelet/kubeadm-flags.env"
sudo "$L/bin/kubeletctl" restart
# the containers the kubelet had created in Docker are orphans now (nobody manages them): they are removed, Docker itself stays as it is
sudo "$L/opt/docker/docker" -H "unix://$R/docker.sock" ps -aq --filter name=k8s_ | xargs -r sudo "$L/opt/docker/docker" -H "unix://$R/docker.sock" rm -f >/dev/null
for _ in $(seq 60); do sudo crictl -r "unix://$R/containerd.sock" -i "unix://$R/containerd.sock" ps 2>/dev/null | grep -q " web " && break; sleep 1; done
sudo crictl -r "unix://$R/containerd.sock" -i "unix://$R/containerd.sock" ps
