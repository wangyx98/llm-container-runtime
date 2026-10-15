#!/bin/bash
# Reference: the network of a runc container is decided when the container is CREATED, by the "network" entry of linux.namespaces in config.json: without a "path" runc makes a new
# network namespace; without any entry (or with a path to the host's namespace file) the container shares the namespace runc runs in. The running container keeps the one it was created
# with, so the bundle is changed, the container is deleted and created again. The mount and pid entries stay: only the network entry goes.
set -e
sudo runc delete -f bench61054998
sudo python3 - <<'PY'
import json

p = "/var/lib/bench61054998/bundle/config.json"
c = json.load(open(p))
c["linux"]["namespaces"] = [n for n in c["linux"]["namespaces"] if n["type"] != "network"]
json.dump(c, open(p, "w"), indent=2)
PY
sudo runc run -d --bundle /var/lib/bench61054998/bundle bench61054998 </dev/null >/dev/null 2>&1
sudo runc state bench61054998 | grep -E '"(id|pid|status)"'
