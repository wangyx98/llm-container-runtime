#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: whatever the solution did to /etc/crictl.yaml, grade
# against containerd itself
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench74595635"
RUN_DIR="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
MIRROR_PORT=25635
REPO="library/$CASE_ID-app"
IMAGE_REF="docker.io/library/$CASE_ID-app:latest"
LOG="$STATE_DIR/mirror.log"

echo "[oracle] check 0: containerd must be up and answering on the CRI, and the mirror"
echo "[oracle]          must still be the one setup started..."
# a script that ends right after `systemctl restart containerd` returns before
# the CRI is ready: give containerd up to 15 s to come back before judging it
for _ in $(seq 1 30); do
    sudo systemctl is-active --quiet containerd && $CRICTL info >/dev/null 2>&1 && break
    sleep 0.5
done
sudo systemctl is-active --quiet containerd || { echo "  -> FAIL: containerd is not active"; exit 1; }
$CRICTL info >/dev/null 2>&1 || { echo "  -> FAIL: crictl cannot talk to containerd (is its config valid?)"; exit 1; }
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
LAYER_DIGEST=$(cat "$STATE_DIR/layer_digest" 2>/dev/null || true)
MIRROR_PID=$(cat "$RUN_DIR/mirror.pid" 2>/dev/null || true)
if [ -z "$EXPECTED_ID" ] || [ -z "$LAYER_DIGEST" ]; then
    echo "  -> FAIL: setup's recorded image id / layer digest are missing"
    exit 1
fi
if [ -z "$MIRROR_PID" ] || [ "$(sudo cat "/proc/$MIRROR_PID/comm" 2>/dev/null)" != "python3" ]; then
    echo "  -> FAIL: the mirror that setup started is not running any more"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: wipe every trace of the image first (the CRI's copy, and any"
echo "[oracle]          tag a shortcut may have created in any containerd namespace),"
echo "[oracle]          so that only a real pull can bring it back..."
for id in $($CRICTL images -o json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for img in data.get("images", []):
    names = (img.get("repoTags") or []) + (img.get("repoDigests") or [])
    if any("'"$CASE_ID"'" in n for n in names):
        print(img["id"])
'); do
    $CRICTL rmi "$id" >/dev/null 2>&1 || true
done
for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
    for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$CASE_ID"); do
        sudo ctr -n "$ns" images rm "$ref" >/dev/null 2>&1 || true
    done
done
if $CRICTL images -o json 2>/dev/null | grep -q "$CASE_ID"; then
    echo "  -> FAIL: could not remove the image before the pull test"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: pulling $IMAGE_REF through the CRI, exactly as a kubelet or"
echo "[oracle]          'crictl pull' would, must now succeed..."
: > "$LOG"
if ! timeout 120 $CRICTL -t 90s pull "$IMAGE_REF" >"$STATE_DIR/oracle_pull.out" 2>&1; then
    echo "  -> FAIL: crictl pull $IMAGE_REF failed:"
    head -c 300 "$STATE_DIR/oracle_pull.out" | head -3 | sed 's/^/     /'
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: the CRI must list that image under that name, and it must be"
echo "[oracle]          THE image the mirror serves (id = sha256 of its config blob)..."
FOUND_ID=$($CRICTL images -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for i in d.get("images", []):
    if any(t == "'"$IMAGE_REF"'" for t in (i.get("repoTags") or [])):
        print(i["id"])
        break
')
if [ "${FOUND_ID#sha256:}" != "$EXPECTED_ID" ]; then
    echo "  -> FAIL: 'crictl images' shows id '${FOUND_ID:-none}' for $IMAGE_REF, expected sha256:$EXPECTED_ID"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 4: the mirror's request log must show that pull: the manifest and"
echo "[oracle]          the layer blob were fetched from it..."
if ! grep -qE "^(GET|HEAD) /v2/$REPO/manifests/" "$LOG"; then
    echo "  -> FAIL: the mirror saw no manifest request during the pull"
    exit 1
fi
if ! grep -qF "GET /v2/$REPO/blobs/$LAYER_DIGEST" "$LOG"; then
    echo "  -> FAIL: the mirror never served the image's layer during the pull"
    exit 1
fi
echo "  -> OK ($(wc -l < "$LOG") requests)"

echo "[oracle] ALL CHECKS PASSED"
