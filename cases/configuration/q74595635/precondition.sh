#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench74595635"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
MIRROR_PORT=25635
REPO="library/$CASE_ID-app"
IMAGE_REF="docker.io/library/$CASE_ID-app:latest"

echo "[precondition] checking containerd is up and answers on the CRI..."
sudo systemctl is-active --quiet containerd
$CRICTL info >/dev/null
echo "  -> OK"

echo "[precondition] checking containerd has NO registry config directory set up..."
if sudo containerd config dump 2>/dev/null | grep -E "^[[:space:]]*config_path[[:space:]]*=" | grep -qvE "=[[:space:]]*(''|\"\")[[:space:]]*$"; then
    echo "  -> FAIL: containerd's effective config already has a config_path"
    exit 1
fi
if [ -e /etc/containerd/certs.d/docker.io ] || [ -e /etc/containerd/certs.d/_default ]; then
    echo "  -> FAIL: a registry hosts directory already exists under /etc/containerd/certs.d"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the mirror is up and serves the image (so the task is"
echo "[precondition] solvable), and has seen no request yet..."
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
if ! echo "$EXPECTED_ID" | grep -qE '^[0-9a-f]{64}$'; then
    echo "  -> FAIL: setup did not record a valid expected image id"
    exit 1
fi
python3 - "$MIRROR_PORT" "$REPO" <<'PYEOF'
import sys, urllib.request
r = urllib.request.urlopen("http://127.0.0.1:%s/v2/%s/manifests/latest" % (sys.argv[1], sys.argv[2]), timeout=3)
assert r.status == 200
PYEOF
: > "$STATE_DIR/mirror.log"
echo "  -> OK"

echo "[precondition] checking the CRI does not hold the image yet..."
if $CRICTL images -o json 2>/dev/null | grep -q "$CASE_ID"; then
    echo "  -> FAIL: the CRI already lists an image named $CASE_ID"
    exit 1
fi
echo "  -> OK"

echo "[precondition] reproducing the symptom: pulling $IMAGE_REF must fail, and the"
echo "[precondition] mirror must not see a single request..."
if timeout 90 $CRICTL -t 60s pull "$IMAGE_REF" >"$STATE_DIR/precondition_pull.out" 2>&1; then
    echo "  -> FAIL: the pull succeeded; the environment is not broken"
    exit 1
fi
if [ -s "$STATE_DIR/mirror.log" ]; then
    echo "  -> FAIL: the mirror already saw requests although containerd is not configured for it"
    exit 1
fi
head -c 300 "$STATE_DIR/precondition_pull.out" | head -2 | sed 's/^/  -> /'
echo "  -> OK (the pull fails and bypasses the mirror)"

echo "[precondition] PASS - the mirror holds the image, containerd does not use it."
