#!/bin/bash
# ctr works in ONE containerd namespace, "default" unless -n is given. MicroK8s keeps its images and containers in the namespace k8s.io (`ctr namespaces ls`
# shows it), so `ctr containers ls` and `ctr images ls` show nothing and `-n k8s.io` shows everything. The digest of an image is in `ctr images ls` (DIGEST),
# the PID of a container's process in `ctr tasks ls` (a container without a task has none); `containers ls` has neither. The node's containerd is not at the
# default socket, so the socket is given (and the other socket is left alone).
set -e
cat > /tmp/bench61055917/list-node.sh <<'SCRIPT'
#!/bin/bash
# list-node.sh OUTPUT_FILE
python3 - /run/bench61055917/containerd/containerd.sock "$1" <<'PY'
import json
import subprocess
import sys

sock, out = sys.argv[1:3]


def ctr(*args):
    return subprocess.run(["sudo", "ctr", "-a", sock, "-n", "k8s.io", *args], capture_output=True, text=True, check=True).stdout


digests = {}
for line in ctr("images", "ls").splitlines()[1:]:
    f = line.split()
    digests[f[0]] = f[2]
names = {r: d for r, d in digests.items() if not r.startswith("sha256:")}      # the CRI plugin also lists every image under its bare ID
pids = {}
for line in ctr("tasks", "ls").splitlines()[1:]:
    f = line.split()
    pids[f[0]] = int(f[1])
containers = []
for line in ctr("containers", "ls").splitlines()[1:]:
    cid, image = line.split()[:2]
    containers.append({"id": cid, "image": image, "digest": digests[image], "pid": pids.get(cid)})
json.dump({"containers": containers, "images": [{"ref": r, "digest": d} for r, d in names.items()]}, open(sys.argv[2], "w"), indent=1)
PY
SCRIPT
chmod +x /tmp/bench61055917/list-node.sh

bash /tmp/bench61055917/list-node.sh /tmp/bench61055917/node.json
python3 -c 'import json; [print(c["id"][:12], c["pid"], c["image"], c["digest"][:19]) for c in json.load(open("/tmp/bench61055917/node.json"))["containers"]]'
