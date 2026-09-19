#!/bin/bash
set -e

POD_NAME="bench69295491-pod"
CONTAINER_NAME="bench69295491"
HOST_DIR="/tmp/bench69295491/hostdir"

echo "[precondition] checking CRI-O is up and crictl can reach it..."
sudo systemctl is-active --quiet crio.service
sudo crictl info >/dev/null

echo "[precondition] checking the host seed file exists (setup ran)..."
test -f "$HOST_DIR/data.txt"

echo "[precondition] checking no pod sandbox named '$POD_NAME' already exists..."
EXISTING_POD=$(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null || true)
if [ -n "$EXISTING_POD" ]; then
    echo "  -> FAIL: a pod sandbox named '$POD_NAME' already exists ($EXISTING_POD)"
    exit 1
fi

echo "[precondition] checking no container named '$CONTAINER_NAME' already exists..."
EXISTING_CTR=$(sudo crictl ps -a --name "$CONTAINER_NAME" -q 2>/dev/null || true)
if [ -n "$EXISTING_CTR" ]; then
    echo "  -> FAIL: a container named '$CONTAINER_NAME' already exists ($EXISTING_CTR)"
    exit 1
fi

echo "[precondition] PASS - CRI-O is healthy, the seed file exists on the host,"
echo "[precondition]        and the target pod/container do not exist yet."
