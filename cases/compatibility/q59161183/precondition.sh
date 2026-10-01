#!/bin/bash
set -e

POD_NAME="bench59161183-pod"
CONTAINER_NAME="bench59161183"
WORK_DIR="/tmp/bench59161183"
STATE_DIR="$WORK_DIR/.bench"
TARBALL="$WORK_DIR/app.tar"
CRIO_NAME="localhost/bench59161183/app:local"
NAME_PREFIX="bench59161183/"

echo "[precondition] checking CRI-O is up and crictl can reach it..."
sudo systemctl is-active --quiet crio.service
sudo crictl info >/dev/null
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
if ! tar -tf "$TARBALL" | grep -qx 'manifest.json'; then
    echo "  -> FAIL: $TARBALL has no manifest.json (not a docker-archive)"
    exit 1
fi
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
if ! echo "$EXPECTED_ID" | grep -qE '^[0-9a-f]{64}$'; then
    echo "  -> FAIL: setup did not record a valid expected image id"
    exit 1
fi
echo "  -> OK (expected image id sha256:$EXPECTED_ID)"

echo "[precondition] checking there is no Docker daemon on this host (the"
echo "[precondition] scenario is a host that only has the tarball)..."
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "  -> FAIL: a Docker daemon is reachable; this case assumes there is none"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking no pod sandbox / container of this case exists..."
EXISTING_POD=$(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null || true)
if [ -n "$EXISTING_POD" ]; then
    echo "  -> FAIL: a pod sandbox named '$POD_NAME' already exists ($EXISTING_POD)"
    exit 1
fi
EXISTING_CTR=$(sudo crictl ps -a --name "$CONTAINER_NAME" -q 2>/dev/null || true)
if [ -n "$EXISTING_CTR" ]; then
    echo "  -> FAIL: a container named '$CONTAINER_NAME' already exists ($EXISTING_CTR)"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking CRI-O does NOT know the image yet (by name or by id)..."
KNOWN=$(sudo crictl images -o json 2>/dev/null | python3 -c '
import json, sys
expected = "'"$EXPECTED_ID"'"
prefix = "'"$NAME_PREFIX"'"
data = json.load(sys.stdin)
hits = []
for img in data.get("images", []):
    ident = img.get("id", "").replace("sha256:", "")
    names = (img.get("repoTags") or []) + (img.get("repoDigests") or [])
    if ident == expected or any(prefix in n for n in names):
        hits.append(img.get("id", "?"))
print(" ".join(hits))
')
if [ -n "$KNOWN" ]; then
    echo "  -> FAIL: CRI-O already has the image ($KNOWN)"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the image is not hiding in podman's root store"
echo "[precondition] (which CRI-O shares) or in containerd's stores..."
if command -v podman >/dev/null 2>&1; then
    if sudo podman images --format '{{.Repository}}' 2>/dev/null | grep -qF "$NAME_PREFIX"; then
        echo "  -> FAIL: podman's root store already has the image"
        exit 1
    fi
fi
if command -v ctr >/dev/null 2>&1; then
    for ns in default k8s.io moby; do
        if sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -qF "$NAME_PREFIX"; then
            echo "  -> FAIL: containerd namespace '$ns' already has the image"
            exit 1
        fi
    done
fi
echo "  -> OK"

echo "[precondition] reproducing the symptom: asking CRI-O to pull the image"
echo "[precondition] must fail, because no registry holds it..."
if sudo crictl pull "$CRIO_NAME" >/dev/null 2>&1; then
    echo "  -> FAIL: 'crictl pull $CRIO_NAME' succeeded; something serves that name"
    exit 1
fi
echo "  -> OK (pull fails as expected)"

echo "[precondition] PASS - CRI-O is healthy, the only copy of the image is the"
echo "[precondition]        tarball, and CRI-O cannot see it yet."
