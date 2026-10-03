#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench74595501"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/bench74595501-app:latest"

echo "[precondition] checking containerd is up and answers on the CRI..."
sudo systemctl is-active --quiet containerd
sudo ctr version >/dev/null
$CRICTL info >/dev/null
echo "  -> OK"

echo "[precondition] checking the image is in the 'default' namespace, and that it runs"
echo "[precondition] from there..."
if ! sudo ctr -n default images ls -q 2>/dev/null | grep -qxF "$IMAGE_REF"; then
    echo "  -> FAIL: 'ctr -n default images ls' does not list $IMAGE_REF"
    exit 1
fi
TOKEN=$(cat "$STATE_DIR/token")
OUT=$(sudo timeout -k 5 30 ctr -n default run --rm "$IMAGE_REF" bench74595501-probe </dev/null 2>&1) && RC=0 || RC=$?
sudo ctr -n default containers rm bench74595501-probe >/dev/null 2>&1 || true
if [ "$RC" -ne 0 ] || ! echo "$OUT" | grep -qxF "bench74595501-app token=$TOKEN"; then
    echo "  -> FAIL: a container from the default-namespace image did not print its line (exit $RC): $(echo "$OUT" | tail -3)"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the image is NOT in the 'k8s.io' namespace, and that the CRI"
echo "[precondition] (which is where Kubernetes looks for it) cannot see it..."
if sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -qF "bench74595501"; then
    echo "  -> FAIL: namespace k8s.io already has an image named like this case's"
    exit 1
fi
if $CRICTL images 2>/dev/null | grep -qF "bench74595501"; then
    echo "  -> FAIL: 'crictl images' already lists the image"
    exit 1
fi
if $CRICTL inspecti "$IMAGE_REF" >/dev/null 2>&1; then
    echo "  -> FAIL: 'crictl inspecti' already finds $IMAGE_REF"
    exit 1
fi
echo "  -> OK (crictl inspecti: no such image)"

echo "[precondition] all checks passed."
