#!/bin/bash
# The kernel does not let a user namespace that does not own the network namespace mount sysfs (a sysfs mount needs CAP_SYS_ADMIN over the network namespace it shows): with the user
# namespace and the host's network namespace together the "sysfs" mount of config.json at /sys fails with "operation not permitted", whatever runc or ctr flags are used. Without the
# mapping, or with a network namespace of its own, it works. The options, from the runc issue: do not mount sysfs (remove the mount), or bind-mount the host's /sys read-only. Here the
# sysfs mount becomes a read-only recursive bind mount of the host's /sys (the cgroup mount below it comes with the recursive bind, so it is dropped). The mapping and the host's network
# namespace stay as they are.
set -e
sudo python3 - <<'PY'
import json

p = "/var/lib/bench66547508/bundle/config.json"
c = json.load(open(p))
mounts = []
for m in c["mounts"]:
    if m["destination"] == "/sys":
        m = {"destination": "/sys", "type": "bind", "source": "/sys", "options": ["rbind", "nosuid", "noexec", "nodev", "ro"]}
    elif m["destination"] == "/sys/fs/cgroup":
        continue
    mounts.append(m)
c["mounts"] = mounts
json.dump(c, open(p, "w"), indent=2)
PY
sudo runc run -d --bundle /var/lib/bench66547508/bundle bench66547508 </dev/null >/dev/null 2>&1
sudo runc state bench66547508 | grep -E '"(id|pid|status)"'
