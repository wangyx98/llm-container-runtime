#!/bin/bash
set -e

NODE_A="/run/bench75568311/node-a/containerd.sock"
NODE_B="/run/bench75568311/node-b/containerd.sock"
# explicit endpoints: do not depend on what /etc/crictl.yaml currently says
CRICTL_A="sudo crictl --runtime-endpoint unix://$NODE_A --image-endpoint unix://$NODE_A --timeout 30s"
CRICTL_B="sudo crictl --runtime-endpoint unix://$NODE_B --image-endpoint unix://$NODE_B --timeout 30s"
POD_NAME="bench75568311-pod"
CONTAINER_NAME="bench75568311"
WORK_DIR="/tmp/bench75568311"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/bench75568311-app:latest"

echo "[precondition] checking both nodes (containerd daemons) are up and answer on the CRI..."
$CRICTL_A info >/dev/null
$CRICTL_B info >/dev/null
echo "  -> OK"

echo "[precondition] checking setup's recorded state and the workload configs..."
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
if ! echo "$EXPECTED_ID" | grep -qE '^[0-9a-f]{64}$'; then
    echo "  -> FAIL: setup did not record a valid expected image id"
    exit 1
fi
for f in pod-config.json container-config.json; do
    [ -s "$WORK_DIR/$f" ] || { echo "  -> FAIL: $WORK_DIR/$f is missing"; exit 1; }
done
echo "  -> OK (expected image id sha256:$EXPECTED_ID)"

echo "[precondition] checking node-a has the image in its k8s.io namespace, for ctr"
echo "[precondition] and for its CRI (the 'but the image is there!' half of the symptom)..."
if ! sudo ctr -a "$NODE_A" -n k8s.io images ls -q 2>/dev/null | grep -qxF "$IMAGE_REF"; then
    echo "  -> FAIL: node-a's 'ctr -n k8s.io images ls' does not show $IMAGE_REF"
    exit 1
fi
A_ID=$($CRICTL_A images -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(next((i["id"] for i in d.get("images", []) if any("bench75568311-app:latest" in t for t in (i.get("repoTags") or []))), ""))
')
if [ "${A_ID#sha256:}" != "$EXPECTED_ID" ]; then
    echo "  -> FAIL: node-a's CRI does not list the image with the expected id (got '${A_ID:-nothing}')"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking node-b does NOT have the image, in any namespace and"
echo "[precondition] in its CRI view (by name or by id)..."
for ns in $(sudo ctr -a "$NODE_B" namespaces ls -q 2>/dev/null); do
    if sudo ctr -a "$NODE_B" -n "$ns" images ls -q 2>/dev/null | grep -qF "bench75568311-app"; then
        echo "  -> FAIL: node-b already has the image in namespace '$ns'"
        exit 1
    fi
done
KNOWN=$($CRICTL_B images -o json 2>/dev/null | python3 -c '
import json, sys
expected = "'"$EXPECTED_ID"'"
data = json.load(sys.stdin)
hits = []
for img in data.get("images", []):
    ident = img.get("id", "").replace("sha256:", "")
    names = (img.get("repoTags") or []) + (img.get("repoDigests") or [])
    if ident == expected or any("bench75568311-app" in n for n in names):
        hits.append(img.get("id", "?"))
print(" ".join(hits))
')
if [ -n "$KNOWN" ]; then
    echo "  -> FAIL: node-b's CRI already lists the image ($KNOWN)"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking node-a runs no pod sandbox or container of its own..."
if [ -n "$($CRICTL_A pods -q 2>/dev/null)" ] || [ -n "$($CRICTL_A ps -a -q 2>/dev/null)" ]; then
    echo "  -> FAIL: node-a already has pod sandboxes or containers"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking node-b's pod sandbox is up (the 'scheduled' pod) and"
echo "[precondition] no container exists in it yet..."
POD_ID=$(cat "$STATE_DIR/pod_id" 2>/dev/null || true)
LISTED=$($CRICTL_B pods -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join(p["id"] + ":" + p["state"] for p in d.get("items", [])))
')
if [ "$LISTED" != "$POD_ID:SANDBOX_READY" ]; then
    echo "  -> FAIL: expected exactly the recorded pod sandbox READY on node-b, got '$LISTED'"
    exit 1
fi
if [ -n "$($CRICTL_B ps -a -q 2>/dev/null)" ]; then
    echo "  -> FAIL: node-b already has a container"
    exit 1
fi
echo "  -> OK (pod sandbox $POD_ID)"

echo "[precondition] reproducing the symptom: creating the container on node-b must fail..."
if $CRICTL_B create "$POD_ID" "$WORK_DIR/container-config.json" "$WORK_DIR/pod-config.json" >/dev/null 2>&1; then
    echo "  -> FAIL: container creation succeeded; the environment is not broken"
    exit 1
fi
echo "  -> OK (creation fails as in the bug report)"

echo "[precondition] PASS - the image exists on node-a only, node-b has a Ready pod"
echo "[precondition]        sandbox and cannot create the container."
