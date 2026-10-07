#!/bin/bash
set -e

POD_JSON="/tmp/bench58429514/pod.json"
SLICE="podbench58429514.slice"

echo "[solution] CRI-O stays on cgroup_manager=systemd; only the pod's cgroup_parent is changed"
echo "[solution] from a cgroupfs-style path to a systemd slice name ($SLICE)..."
python3 - "$POD_JSON" "$SLICE" <<'PY'
import json, sys
path, slice_name = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg["linux"]["cgroup_parent"] = slice_name
json.dump(cfg, open(path, "w"), indent=2)
PY

echo "[solution] the pod sandbox can now be started with the unchanged CRI-O config:"
sudo crictl runp "$POD_JSON"
