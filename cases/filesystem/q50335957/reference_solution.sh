#!/bin/bash
# The mount of /proc is a copy of a mount whose flags (nosuid,nodev,noexec) are locked in the user namespace's mount namespace: the read-only remount has to repeat them.
sudo python3 - /var/lib/bench50335957/bundle/config.json <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
for m in c["mounts"]:
    if m["destination"] == "/test-proc":
        m["options"] = ["rbind", "ro", "nosuid", "nodev", "noexec"]
json.dump(c, open(p, "w"), indent=2)
PY
