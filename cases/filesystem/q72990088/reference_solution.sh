#!/bin/bash
# Reference: the source of the file mount in ctr.json is a relative path, and a relative source of an OCI bind mount is resolved by runc against the container's bundle directory (below the runtime's task
# directory), not against where the manifest or the caller is. The file is in the deployment directory: give the mount its absolute path (nothing else changes) and apply the deployment again.
set -e
D=/var/lib/bench72990088/deploy
sudo python3 - "$D" <<'PY'
import json, sys
d = sys.argv[1]
c = json.load(open(d + "/ctr.json"))
m = [x for x in c["mounts"] if x["container_path"] == "/app/config/local.json"][0]
m["host_path"] = d + "/" + m["host_path"]
json.dump(c, open(d + "/ctr.json", "w"), indent=2)
PY
sudo "$D/launch.sh"
