#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: do not depend on what /etc/crictl.yaml currently says
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
WORK_DIR="/tmp/bench78814823"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/bench78814823-app:latest"

echo "[precondition] checking containerd is up and answers on the CRI..."
sudo systemctl is-active --quiet containerd
$CRICTL info >/dev/null
echo "  -> OK"

echo "[precondition] checking setup's recorded ground truth..."
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
if ! echo "$EXPECTED_ID" | grep -qE '^[0-9a-f]{64}$'; then
    echo "  -> FAIL: setup did not record a valid expected image id"
    exit 1
fi
NS=$(cat "$STATE_DIR/namespace" 2>/dev/null || true)
if [ -z "$NS" ]; then
    echo "  -> FAIL: setup did not record the namespace that holds the image"
    exit 1
fi
if [ -e "$WORK_DIR/report.json" ]; then
    echo "  -> FAIL: a report.json already exists before the solution ran"
    exit 1
fi
echo "  -> OK (image id sha256:$EXPECTED_ID, namespace '$NS')"

echo "[precondition] checking the CRI lists the image, with that id..."
CRI_ID=$($CRICTL images -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(next((i["id"] for i in d.get("images", []) if any("bench78814823-app:latest" in t for t in (i.get("repoTags") or []))), ""))
')
if [ "${CRI_ID#sha256:}" != "$EXPECTED_ID" ]; then
    echo "  -> FAIL: 'crictl images' does not list the image with the expected id (got '${CRI_ID:-nothing}')"
    exit 1
fi
echo "  -> OK"

echo "[precondition] reproducing the symptom: a plain 'ctr images list' (default"
echo "[precondition] namespace) must NOT show the image..."
if sudo ctr images ls -q 2>/dev/null | grep -qF "bench78814823"; then
    echo "  -> FAIL: the default namespace already shows the image"
    exit 1
fi
echo "  -> OK (the default namespace has nothing of this case)"

echo "[precondition] checking the image is in exactly one namespace, the recorded one..."
HOLDERS=""
for ns in $(sudo ctr namespaces ls -q); do
    if sudo ctr -n "$ns" images ls -q | grep -qxF "$IMAGE_REF"; then
        HOLDERS="$HOLDERS $ns"
    fi
done
HOLDERS=$(echo $HOLDERS)
if [ "$HOLDERS" != "$NS" ]; then
    echo "  -> FAIL: the image is in namespace(s) '$HOLDERS', expected only '$NS'"
    exit 1
fi
echo "  -> OK"

echo "[precondition] PASS - the CRI lists the image, plain ctr does not, and the"
echo "[precondition]        image sits in namespace '$NS'."
