#!/bin/bash
set -e

WORK_DIR="/tmp/bench78814823"
IMAGE_REF="docker.io/library/bench78814823-app:latest"

echo "[solution] 'ctr' only looks into ONE containerd namespace at a time ('default'"
echo "[solution] unless told otherwise), while the CRI keeps its images in 'k8s.io'."
echo "[solution] Asking every namespace which one holds the image:"
NS=""
for ns in $(sudo ctr namespaces ls -q); do
    if sudo ctr -n "$ns" images ls -q | grep -qxF "$IMAGE_REF"; then
        NS="$ns"
        break
    fi
done
[ -n "$NS" ] || { echo "[solution] image not found in any namespace"; exit 1; }
echo "[solution] -> namespace: $NS"

echo "[solution] the full image ID as the CRI reports it:"
IMAGE_ID=$(sudo crictl images -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(next(i["id"] for i in d["images"] if any("bench78814823-app:latest" in t for t in (i.get("repoTags") or []))))
')
echo "[solution] -> $IMAGE_ID"

echo "[solution] writing the report..."
python3 - "$NS" "$IMAGE_ID" > "$WORK_DIR/report.json" <<'PYEOF'
import json, sys
ns, image_id = sys.argv[1:3]
print(json.dumps({
    "namespace": ns,
    "image_id": image_id,
    "ctr_command": "sudo ctr -n %s images ls" % ns,
}, indent=2))
PYEOF
cat "$WORK_DIR/report.json"
