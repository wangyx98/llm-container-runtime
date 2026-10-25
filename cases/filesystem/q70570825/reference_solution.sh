#!/bin/bash
# Reference: CRI's PodSandboxConfig has no mounts (runp ignores the unknown `mounts` of pod.json without a word); the mounts of a workload are the `mounts` of the container's ContainerConfig
# (container_path, host_path, readonly). Put them in ctr.json with the absolute host paths and apply the deployment again.
set -e
D=/var/lib/bench70570825/deploy
R=/run/bench70570825/vol
sudo python3 - "$D" "$R" <<'PY'
import json, sys
d, r = sys.argv[1:3]
c = json.load(open(d + "/ctr.json"))
c["mounts"] = [{"container_path": "/docker", "host_path": r + "/share", "readonly": True}, {"container_path": "/data", "host_path": r + "/data"}]
json.dump(c, open(d + "/ctr.json", "w"), indent=2)
PY
sudo "$D/launch.sh"
