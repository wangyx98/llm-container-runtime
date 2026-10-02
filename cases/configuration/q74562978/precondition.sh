#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench74562978"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
REGISTRY_PORT=25562
REGISTRY_HOST="registry.bench74562978.test"
REPO="$CASE_ID/app"
IMAGE_REF="$REGISTRY_HOST:$REGISTRY_PORT/$REPO:latest"

echo "[precondition] checking containerd is up and answers on the CRI..."
sudo systemctl is-active --quiet containerd
$CRICTL info >/dev/null
echo "  -> OK"

echo "[precondition] checking the CRI reads per-registry settings from"
echo "[precondition] /etc/containerd/certs.d, and that nothing is configured for the"
echo "[precondition] registry yet..."
if ! sudo containerd config dump 2>/dev/null | grep -E "^[[:space:]]*config_path[[:space:]]*=" | grep -q "/etc/containerd/certs.d"; then
    echo "  -> FAIL: containerd's effective config does not use /etc/containerd/certs.d"
    exit 1
fi
if [ -e "/etc/containerd/certs.d/$REGISTRY_HOST:$REGISTRY_PORT" ] || [ -e /etc/containerd/certs.d/_default ]; then
    echo "  -> FAIL: a hosts directory for the registry already exists"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the registry host name resolves to this machine..."
RESOLVED=$(python3 -c "import socket; print(socket.gethostbyname('$REGISTRY_HOST'))" 2>/dev/null || true)
if [ "$RESOLVED" != "127.0.0.1" ]; then
    echo "  -> FAIL: $REGISTRY_HOST resolves to '${RESOLVED:-nothing}', expected 127.0.0.1"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the registry is up and serves the image over plain HTTP"
echo "[precondition] (so the task is solvable), and has seen no request yet..."
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
if ! echo "$EXPECTED_ID" | grep -qE '^[0-9a-f]{64}$'; then
    echo "  -> FAIL: setup did not record a valid expected image id"
    exit 1
fi
python3 - "$REGISTRY_HOST" "$REGISTRY_PORT" "$REPO" <<'PYEOF'
import sys, urllib.request
r = urllib.request.urlopen("http://%s:%s/v2/%s/manifests/latest" % tuple(sys.argv[1:4]), timeout=3)
assert r.status == 200
PYEOF
: > "$STATE_DIR/registry.log"
echo "  -> OK"

echo "[precondition] checking the CRI does not hold the image yet..."
if $CRICTL images -o json 2>/dev/null | grep -q "$CASE_ID"; then
    echo "  -> FAIL: the CRI already lists an image named $CASE_ID"
    exit 1
fi
echo "  -> OK"

echo "[precondition] reproducing the symptom: pulling $IMAGE_REF must fail,"
echo "[precondition] and the registry must not see a single request..."
if timeout 90 $CRICTL -t 60s pull "$IMAGE_REF" >"$STATE_DIR/precondition_pull.out" 2>&1; then
    echo "  -> FAIL: the pull succeeded; the environment is not broken"
    exit 1
fi
if [ -s "$STATE_DIR/registry.log" ]; then
    echo "  -> FAIL: the registry already saw requests although containerd insists on HTTPS"
    exit 1
fi
head -c 300 "$STATE_DIR/precondition_pull.out" | head -2 | sed 's/^/  -> /'
echo
echo "  -> OK (the pull fails before any HTTP request reaches the registry)"

echo "[precondition] PASS - the registry holds the image over plain HTTP, containerd"
echo "[precondition]        will not talk to it."
