#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: whatever the solution did to /etc/crictl.yaml, grade
# against containerd itself
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench74595501"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/bench74595501-app:latest"
CHECK_ID="bench74595501-check"

echo "[oracle] check 0: containerd must be up, with ctr and the CRI answering..."
for _ in $(seq 1 30); do
    sudo systemctl is-active --quiet containerd && $CRICTL info >/dev/null 2>&1 && break
    sleep 0.5
done
sudo systemctl is-active --quiet containerd || { echo "  -> FAIL: containerd is not active"; exit 1; }
sudo ctr version >/dev/null 2>&1 || { echo "  -> FAIL: ctr cannot talk to containerd"; exit 1; }
$CRICTL info >/dev/null 2>&1 || { echo "  -> FAIL: crictl cannot talk to containerd"; exit 1; }
TOKEN=$(cat "$STATE_DIR/token" 2>/dev/null || true)
IMAGE_ID=$(cat "$STATE_DIR/image_id" 2>/dev/null || true)
if [ -z "$TOKEN" ] || [ -z "$IMAGE_ID" ]; then
    echo "  -> FAIL: setup's recorded token / image id are missing"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: 'ctr -n k8s.io images ls' must list $IMAGE_REF..."
LISTED=$(sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -F "bench74595501" || true)
if ! echo "$LISTED" | grep -qxF "$IMAGE_REF"; then
    echo "  -> FAIL: '$IMAGE_REF' is not listed in namespace k8s.io (bench74595501 names there: ${LISTED:-none})"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: the CRI (what Kubernetes asks) must find the image under that name,"
echo "[oracle]          and it must be the image setup built (same image id)..."
GOT=""
for _ in $(seq 1 20); do
    GOT=$($CRICTL inspecti -o go-template --template '{{.status.id}}' "$IMAGE_REF" 2>/dev/null || true)
    [ -n "$GOT" ] && break
    sleep 0.5
done
if [ -z "$GOT" ]; then
    echo "  -> FAIL: 'crictl inspecti $IMAGE_REF' finds no such image"
    exit 1
fi
if [ "$GOT" != "sha256:$IMAGE_ID" ]; then
    echo "  -> FAIL: the CRI's image under that name has id $GOT, expected sha256:$IMAGE_ID: it is not the image from the default namespace"
    exit 1
fi
echo "  -> OK ($GOT)"

echo "[oracle] check 3: a container run from the k8s.io image must work and print the line"
echo "[oracle]          that only this image's program prints (its random token)..."
sudo ctr -n k8s.io tasks rm -f "$CHECK_ID" >/dev/null 2>&1 || true
sudo ctr -n k8s.io containers rm "$CHECK_ID" >/dev/null 2>&1 || true
# stdin comes from /dev/null on purpose: 'ctr run' copies its stdin into the
# container, and 'timeout' runs it in a background process group, where a read
# from a terminal stops the process (SIGTTIN)
OUT=$(sudo timeout -k 5 30 ctr -n k8s.io run --rm "$IMAGE_REF" "$CHECK_ID" </dev/null 2>&1) && RC=0 || RC=$?
# a wrong image that never exits would leave its container behind
sudo ctr -n k8s.io tasks kill -s SIGKILL "$CHECK_ID" >/dev/null 2>&1 || true
sudo ctr -n k8s.io tasks rm -f "$CHECK_ID" >/dev/null 2>&1 || true
sudo ctr -n k8s.io containers rm "$CHECK_ID" >/dev/null 2>&1 || true
if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then
    echo "  -> FAIL: the container run from $IMAGE_REF did not exit within 30 s (the image's program prints one line and exits)"
    exit 1
fi
if [ "$RC" -ne 0 ]; then
    echo "  -> FAIL: 'ctr run' of $IMAGE_REF in k8s.io failed (exit $RC): $(echo "$OUT" | tail -3)"
    exit 1
fi
if ! echo "$OUT" | grep -qxF "bench74595501-app token=$TOKEN"; then
    echo "  -> FAIL: the container did not print the image's line (got: $(echo "$OUT" | tail -3))"
    exit 1
fi
echo "  -> OK"

echo "[oracle] all checks passed."
