#!/bin/bash
set -e

# A pod's name and namespace are not on the node as files or in cgroup names, but they are in the CRI: the kubelet hands them to the container runtime
# when it creates the pod sandbox (metadata: name, namespace, uid, attempt), and every container carries the name of its pod's sandbox. So the
# mapping is one join in containerd's CRI: the pod sandboxes (READY only: the pods running on the node) by uid, and the containers by their
# sandbox id; of the containers with the same name (restarts have a higher "attempt"), the newest one is the current instance.
cat > /tmp/bench69636534/pods.sh <<'EOF'
#!/bin/bash
SOCK=/run/bench69636534/containerd/containerd.sock
python3 - "$SOCK" <<'PY'
import json
import subprocess
import sys

sock = sys.argv[1]


def crictl(*args):
    out = subprocess.check_output(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, *args, "-o", "json"])
    return json.loads(out)


pods = {p["id"]: p for p in crictl("pods")["items"] if p["state"] == "SANDBOX_READY"}
result = {}
for p in pods.values():
    m = p["metadata"]
    result[m["uid"]] = {"namespace": m["namespace"], "name": m["name"], "containers": {}}
newest = {}
for c in crictl("ps", "-a")["containers"]:
    pod = pods.get(c["podSandboxId"])
    if pod is None:
        continue
    key = (pod["metadata"]["uid"], c["metadata"]["name"])
    if key not in newest or c["metadata"]["attempt"] > newest[key][0]:
        newest[key] = (c["metadata"]["attempt"], c["id"])
for (uid, name), (_, cid) in newest.items():
    result[uid]["containers"][name] = cid
print(json.dumps(result, indent=2, sort_keys=True))
PY
EOF
chmod +x /tmp/bench69636534/pods.sh
echo "[solution] the script's answer now:"
bash /tmp/bench69636534/pods.sh
