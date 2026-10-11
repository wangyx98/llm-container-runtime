#!/bin/bash
# Every process of a container is in the container's cgroup, whatever its depth or its parent: /proc/PID/cgroup names it (for containerd's runc
# containers the cgroup path ends with the container ID, in cgroup v1 and v2 alike), and `crictl inspect` gives, for that container ID, the pod's
# labels (io.kubernetes.pod.uid, .namespace, .name; io.kubernetes.container.name) and the PID of the first process (info.pid). A process of the node
# has no container ID in its cgroup. The node's containerd is not at the default socket, so the endpoint is given.
set -e
cat > /tmp/bench70948748/pid-owner.sh <<'SCRIPT'
#!/bin/bash
# pid-owner.sh PID OUTPUT_FILE
set -e
python3 - "$@" <<'PY'
import json
import re
import subprocess
import sys

SOCK = "/run/bench70948748/containerd/containerd.sock"
pid, out = sys.argv[1:3]
owner = None
try:
    cgroup = open("/proc/%s/cgroup" % pid).read()
except OSError:
    cgroup = ""
for cid in dict.fromkeys(re.findall(r"[0-9a-f]{64}", cgroup)):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + SOCK, "--image-endpoint", "unix://" + SOCK, "inspect", "-o", "json", cid],
                       capture_output=True, text=True)
    if r.returncode != 0:                       # an ID that is not a container (a pod sandbox, for one)
        continue
    d = json.loads(r.stdout)
    labels = d["status"]["labels"]
    owner = {"container_id": d["status"]["id"], "pod_uid": labels["io.kubernetes.pod.uid"], "pod_namespace": labels["io.kubernetes.pod.namespace"],
             "pod_name": labels["io.kubernetes.pod.name"], "container_name": labels["io.kubernetes.container.name"], "init_pid": int(d["info"]["pid"])}
    break
json.dump(owner, open(out, "w"))
PY
SCRIPT
chmod +x /tmp/bench70948748/pid-owner.sh

bash /tmp/bench70948748/pid-owner.sh "$(cat /tmp/bench70948748/target.pid)" /tmp/bench70948748/owner.json
cat /tmp/bench70948748/owner.json
