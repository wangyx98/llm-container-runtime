#!/bin/bash
set -e

CRI=/tmp/bench76134722/bin/node-crictl
CTR=/tmp/bench76134722/bin/node-ctr
KEEP=/var/lib/bench76134722/keep-images.txt

echo "[solution] the idle images with a dev- tag that are not on the keep list: an image that carries only such names is removed through the CRI (all its names and its blobs go); an image that also carries another name only loses its dev- name (ctr removes one name); images in use and pinned images are left alone"
$CRI images -o json > /tmp/bench76134722/images.json
$CRI ps -a -o json > /tmp/bench76134722/ctrs.json
python3 - "$KEEP" <<'PYEOF'
import json, subprocess, sys
CRI, CTR = "/tmp/bench76134722/bin/node-crictl", "/tmp/bench76134722/bin/node-ctr"
keep = {l.strip() for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")}
used = {c["imageRef"] for c in json.load(open("/tmp/bench76134722/ctrs.json"))["containers"]}
for img in json.load(open("/tmp/bench76134722/images.json"))["images"]:
    if img["id"] in used or img.get("pinned"): continue
    tags = img["repoTags"]
    gone = [t for t in tags if t.rsplit(":", 1)[1].startswith("dev-") and t not in keep]
    if not gone: continue
    if len(gone) == len(tags):
        print("rmi", img["id"][:19], tags); subprocess.run([CRI, "rmi", img["id"]], check=True)
    else:
        for t in gone:
            print("untag", t); subprocess.run([CTR, "-n", "k8s.io", "images", "rm", t], check=True)
PYEOF
rm -f /tmp/bench76134722/images.json /tmp/bench76134722/ctrs.json
$CRI images
