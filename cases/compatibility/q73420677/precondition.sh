#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: do not depend on what /etc/crictl.yaml currently says
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
POD_NAME="bench73420677-pod"
CONTAINER_NAME="bench73420677"
WORK_DIR="/tmp/bench73420677"
STATE_DIR="$WORK_DIR/.bench"
TARBALL="$WORK_DIR/app.tar"
IMAGE_REF="docker.io/library/bench73420677-app:latest"

echo "[precondition] checking containerd is up and answers on the CRI..."
sudo systemctl is-active --quiet containerd
$CRICTL info >/dev/null
echo "  -> OK"

echo "[precondition] checking the 'docker save' style tarball is present and"
echo "[precondition] exactly as setup wrote it..."
if [ ! -s "$TARBALL" ]; then
    echo "  -> FAIL: $TARBALL is missing"
    exit 1
fi
EXPECTED_SHA=$(cat "$STATE_DIR/tarball.sha256" 2>/dev/null || true)
ACTUAL_SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "  -> FAIL: tarball hash does not match what setup recorded"
    exit 1
fi
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
if ! echo "$EXPECTED_ID" | grep -qE '^[0-9a-f]{64}$'; then
    echo "  -> FAIL: setup did not record a valid expected image id"
    exit 1
fi
for f in pod-config.json container-config.json; do
    [ -s "$WORK_DIR/$f" ] || { echo "  -> FAIL: $WORK_DIR/$f is missing"; exit 1; }
done
echo "  -> OK (expected image id sha256:$EXPECTED_ID)"

echo "[precondition] checking the image really 'exists' for ctr, in its default"
echo "[precondition] namespace (the 'but the image is there!' half of the symptom)..."
if ! sudo ctr -n default images ls -q 2>/dev/null | grep -qxF "$IMAGE_REF"; then
    echo "  -> FAIL: 'ctr images ls' does not show $IMAGE_REF"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the CRI does NOT see it (by name or by id)..."
KNOWN=$($CRICTL images -o json 2>/dev/null | python3 -c '
import json, sys
expected = "'"$EXPECTED_ID"'"
data = json.load(sys.stdin)
hits = []
for img in data.get("images", []):
    ident = img.get("id", "").replace("sha256:", "")
    names = (img.get("repoTags") or []) + (img.get("repoDigests") or [])
    if ident == expected or any("bench73420677" in n for n in names):
        hits.append(img.get("id", "?"))
print(" ".join(hits))
')
if [ -n "$KNOWN" ]; then
    echo "  -> FAIL: the CRI already lists the image ($KNOWN)"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the pod sandbox is up (the 'scheduled' pod) and"
echo "[precondition] no container exists in it yet..."
POD_ID=$(cat "$STATE_DIR/pod_id" 2>/dev/null || true)
LISTED=$($CRICTL pods --name "$POD_NAME" -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join(p["id"] + ":" + p["state"] for p in d.get("items", []) if p["metadata"]["name"] == "'"$POD_NAME"'"))
')
if [ "$LISTED" != "$POD_ID:SANDBOX_READY" ]; then
    echo "  -> FAIL: expected exactly the recorded pod sandbox READY, got '$LISTED'"
    exit 1
fi
EXISTING_CTR=$($CRICTL ps -a --name "$CONTAINER_NAME" -q 2>/dev/null || true)
if [ -n "$EXISTING_CTR" ]; then
    echo "  -> FAIL: a container named '$CONTAINER_NAME' already exists ($EXISTING_CTR)"
    exit 1
fi
echo "  -> OK (pod sandbox $POD_ID)"

echo "[precondition] reproducing the symptom: creating the container must fail..."
if $CRICTL create "$POD_ID" "$WORK_DIR/container-config.json" "$WORK_DIR/pod-config.json" >/dev/null 2>&1; then
    echo "  -> FAIL: container creation succeeded; the environment is not broken"
    exit 1
fi
echo "  -> OK (creation fails as in the bug report)"

echo "[precondition] PASS - ctr shows the image, the CRI does not, the sandbox is"
echo "[precondition]        Ready and the container cannot be created yet."
