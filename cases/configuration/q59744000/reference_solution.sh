#!/bin/bash
# The CRI plugin of containerd runs runc with SystemdCgroup = true, so runc wants a cgroup parent in the systemd style (a slice name such as
# kubepods-burstable-pod<uid>.slice). The kubelet is configured with cgroupDriver: cgroupfs and sends /kubepods/burstable/pod<uid>, which runc rejects
# ("expected cgroupsPath to be of format slice:prefix:name"): no pod sandbox starts, so calico-node never runs, the CNI is never configured and the node stays NotReady.
# The kubelet and the runtime must use the same cgroup driver. containerd stays on systemd (the host's init is systemd: one cgroup manager); the kubelet
# changes to the systemd driver, then it starts the pods again.
set -e
sudo grep -n 'SystemdCgroup' /var/lib/bench59744000/etc/containerd.toml
sudo grep -n '^cgroupDriver' /var/lib/bench59744000/etc/kubelet-config.yaml
sudo sed -i 's/^cgroupDriver: cgroupfs$/cgroupDriver: systemd/' /var/lib/bench59744000/etc/kubelet-config.yaml
sudo grep -n '^cgroupDriver' /var/lib/bench59744000/etc/kubelet-config.yaml
sudo /var/lib/bench59744000/bin/kubelet-sim sync
