#!/bin/bash
set -e

# Remove the images whose name matches 'foo|bar' and that no container uses, and nothing else.
#  - "in use" = referenced by ANY container still on the node, exited ones included (crictl ps -a); nothing is stopped or removed.
#  - `crictl rmi` removes the image together with ALL its names, so it is only right for an image that has no name outside the
#    filter. An unused image that also has a name the filter does not match (a second tag on the same image) only loses the
#    matching names: `ctr images rm <name>` removes one name and leaves the image under the others.
SOCK=/run/bench68660550/containerd.sock
CRI="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CTR="sudo ctr -a $SOCK -n k8s.io"

$CRI ps -a -o json > /tmp/bench68660550-ps.json
$CRI images -o json > /tmp/bench68660550-images.json

python3 - /tmp/bench68660550-ps.json /tmp/bench68660550-images.json 'foo|bar' > /tmp/bench68660550-plan.txt <<'PY'
import json, re, sys
ps, images, pattern = sys.argv[1:4]
used = {c["imageRef"] for c in json.load(open(ps))["containers"]}
for img in json.load(open(images))["images"]:
    if img["id"] in used:
        continue
    match = [t for t in img.get("repoTags", []) if re.search(pattern, t)]
    other = [t for t in img.get("repoTags", []) if not re.search(pattern, t)]
    if not match:
        continue
    if other:
        for t in match:
            print("name", t)
    else:
        print("image", img["id"])
PY
cat /tmp/bench68660550-plan.txt

while read -r kind what; do
    case "$kind" in
        image) $CRI rmi "$what" ;;
        name)  $CTR images rm "$what" ;;
    esac
done < /tmp/bench68660550-plan.txt
rm -f /tmp/bench68660550-ps.json /tmp/bench68660550-images.json /tmp/bench68660550-plan.txt

$CRI images
