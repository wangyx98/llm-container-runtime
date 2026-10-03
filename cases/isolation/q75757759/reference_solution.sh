#!/bin/bash
set -e

# A container's capabilities are fixed when it is created, so the container
# has to be replaced. ping is installed with the file capability cap_net_raw
# (it opens a raw ICMP socket): with every capability dropped the kernel
# refuses to execute it at all ("operation not permitted"). The least
# privilege fix keeps "drop ALL" and adds back only NET_RAW; privileged would
# work too, but gives the container everything.

WORK=/tmp/bench75757759
POD=$(sudo crictl pods --name bench75757759-pod --state ready -q | head -1)
echo "[solution] pod $POD"

python3 - "$WORK" <<'PYEOF'
import json
import sys

work = sys.argv[1]
c = json.load(open(work + "/container.json"))
c["linux"]["security_context"]["capabilities"]["add_capabilities"] = ["NET_RAW"]
json.dump(c, open(work + "/container-fixed.json", "w"), indent=2)
PYEOF

echo "[solution] removing the broken container..."
for id in $(sudo crictl ps -a -q --name '^bench75757759-ping$'); do
    sudo crictl stop --timeout 1 "$id" >/dev/null 2>&1 || true
    sudo crictl rm -f "$id"
done

echo "[solution] creating and starting it again with NET_RAW added back..."
CID=$(sudo crictl create "$POD" "$WORK/container-fixed.json" "$WORK/pod.json")
sudo crictl start "$CID"

echo "[solution] ping inside the new container:"
sudo crictl exec "$CID" /usr/bin/ping -c 1 127.0.0.1
