#!/bin/bash
# Reference: ctr and nerdctl talk to containerd's `default` namespace (empty here); the CRI keeps the node's images in `k8s.io` and crictl is already bound to it. The job runs crictl in the purger's
# container (the node's socket is mounted there): the images under scratch/ that no container uses are removed BY ID (all their names and the id record go), the rest stays; running it again is harmless.
set -e
J=/var/lib/bench66960498/job/purge-images.sh
sudo tee "$J" >/dev/null <<'JOB'
#!/bin/bash
# purge-images.sh: removes the images of the repositories below bench66960498.local/scratch/ that no container of the node uses, through the container of the Pod purger
set -e
node=/var/lib/bench66960498/bin/crictl
pod=$("$node" pods --name '^purger$' --state ready -q)
cid=$("$node" ps --pod "$pod" --state running -q)
in_pod() { "$node" exec "$cid" /crictl -r unix:///run/containerd/containerd.sock "$@"; }
python3 - "$(in_pod images -o json)" "$(in_pod ps -a -o json)" <<'PY' | while read -r id; do in_pod rmi "$id" >/dev/null; echo "purged $id"; done
import json, sys
used = {c["imageRef"] for c in json.loads(sys.argv[2])["containers"]}
for i in json.loads(sys.argv[1])["images"]:
    if any(t.startswith("bench66960498.local/scratch/") for t in i["repoTags"]) and i["id"] not in used:
        print(i["id"])
PY
JOB
sudo chmod 755 "$J"
sudo "$J"
