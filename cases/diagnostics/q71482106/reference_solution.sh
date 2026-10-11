#!/bin/bash
# The CRI keeps two kinds of objects: containers (`crictl ps -a`, no sandboxes in it) and pod sandboxes (`crictl pods`; each has one container, the
# "pause" one, and the pod's containers join its namespaces). `crictl inspectp` gives the process of a sandbox and `crictl inspect` the one of a container
# (info.pid); the network namespace of a process is what /proc/PID/ns/net points to (read as root). The node's containerd is not at the default
# socket, so the endpoint is given.
set -e
cat > /tmp/bench71482106/pause-map.sh <<'SCRIPT'
#!/bin/bash
# pause-map.sh OUTPUT_FILE
set -e
python3 - "$1" <<'PY'
import json
import subprocess
import sys

SOCK = "/run/bench71482106/containerd/containerd.sock"


def cri(command, *args):
    return json.loads(subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + SOCK, "--image-endpoint", "unix://" + SOCK, command, "-o", "json", *args],
                                     capture_output=True, text=True, check=True).stdout)


def netns(pid):
    link = subprocess.run(["sudo", "readlink", "/proc/%d/ns/net" % pid], capture_output=True, text=True, check=True).stdout.strip()
    return int(link[len("net:["):-1])


containers = cri("ps", "-a")["containers"]
result = []
for pod in cri("pods")["items"]:
    pid = int(cri("inspectp", pod["id"])["info"]["pid"])
    mine = []
    for c in containers:
        if c["podSandboxId"] == pod["id"]:
            cpid = int(cri("inspect", c["id"])["info"]["pid"])
            mine.append({"id": c["id"], "name": c["metadata"]["name"], "pid": cpid, "netns": netns(cpid)})
    result.append({"sandbox_id": pod["id"], "pod": pod["metadata"]["namespace"] + "/" + pod["metadata"]["name"],
                   "pause_pid": pid, "netns": netns(pid), "containers": mine})
json.dump(result, open(sys.argv[1], "w"), indent=1)
PY
SCRIPT
chmod +x /tmp/bench71482106/pause-map.sh

bash /tmp/bench71482106/pause-map.sh /tmp/bench71482106/pause-map.json
