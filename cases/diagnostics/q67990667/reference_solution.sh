#!/bin/bash
# `ctr containers ls` and `ctr containers info ID` work in ONE containerd namespace ("default" unless -n is given); the containers of this node
# are in other namespaces (`ctr namespaces ls`), and the same ID can be in several of them. `containers info` prints the record of the container
# (image, runtime, labels) and its OCI spec (the environment of the process, the mounts) as JSON, but nothing about the task: its state and PID are in
# `ctr tasks ls` of the same namespace, and a container that has no task is not in that list (it has no PID). The node's containerd is not at the
# default socket, so the socket is given.
set -e
cat > /tmp/bench67990667/inspect.sh <<'SCRIPT'
#!/bin/bash
# inspect.sh OUTPUT_FILE
python3 - /run/bench67990667/containerd/containerd.sock "$1" <<'PY'
import json
import subprocess
import sys

sock, out = sys.argv[1:3]


def ctr(*args):
    return subprocess.run(["sudo", "ctr", "-a", sock, *args], capture_output=True, text=True, check=True).stdout


result = []
for ns in ctr("namespaces", "ls", "-q").split():
    tasks = {}
    for line in ctr("-n", ns, "tasks", "ls").splitlines()[1:]:
        f = line.split()
        tasks[f[0]] = (int(f[1]), f[2].lower())
    for cid in ctr("-n", ns, "containers", "ls", "-q").split():
        info = json.loads(ctr("-n", ns, "containers", "info", cid))
        spec = info.get("Spec") or {}
        task = tasks.get(cid)
        result.append({
            "namespace": ns, "id": cid, "image": info["Image"], "runtime": info["Runtime"]["Name"],
            "labels": info.get("Labels") or {}, "env": spec.get("process", {}).get("env", []), "mounts": spec.get("mounts", []),
            "status": task[1] if task else "none", "pid": task[0] if task else None})
json.dump(result, open(sys.argv[2], "w"), indent=1)
PY
SCRIPT
chmod +x /tmp/bench67990667/inspect.sh

bash /tmp/bench67990667/inspect.sh /tmp/bench67990667/containers.json
python3 -c 'import json; [print(c["namespace"], c["id"], c["status"], c["pid"]) for c in json.load(open("/tmp/bench67990667/containers.json"))]'
