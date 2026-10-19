#!/bin/bash
# Reference: the container's memory cgroup is named <pod parent>.slice:cri-containerd:<id> because the pod's parent is a systemd-style slice while the node's runc uses
# cgroupfs (SystemdCgroup = false): the CRI plugin builds the colon form, runc takes it as a literal directory name, and JDK 11.0.9 (JDK-8272124, fixed in 11.0.13) cuts
# the path of /proc/self/cgroup at the colon, finds no memory.limit_in_bytes and reports 0 physical memory. The kubelet-style parent is made a cgroupfs one (the
# cgroup driver of the pod and the node's runc agree); memory limit, image and JVM stay as they are.
set -euo pipefail

L=/var/lib/bench68845002

sudo "$L/bin/cachenodectl" status
sudo "$L/bin/run-workload" diagnose 2>&1 | grep -E "^(probe|cache-)" || true

sudo python3 - <<'PY'
import json
p = "/var/lib/bench68845002/workload/pod.json"
j = json.load(open(p))
j["linux"]["cgroup_parent"] = "/kubepods/burstable/pod6bd1d7f1-9a2c-4a0e-8b3f-c4a1e2d3b5a6"
json.dump(j, open(p, "w"), indent=2)
PY

sudo "$L/bin/cachenodectl" restart
sudo "$L/bin/run-workload" verify 2>&1 | grep -E "^(probe java|probe limit|cache-|workload)"
