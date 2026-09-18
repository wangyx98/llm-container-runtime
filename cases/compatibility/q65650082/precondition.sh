#!/bin/bash
set -e

POD_NAME="bench65650082-pod"
CONTAINER_NAME="bench65650082"

echo "[precondition] checking CRI-O is up and crictl can reach it..."
sudo systemctl is-active --quiet crio.service
sudo crictl info >/dev/null

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

echo "[precondition] PASS - CRI-O is healthy and the target pod/container do"
echo "[precondition]        not exist yet, matching the SO scenario (nothing"
echo "[precondition]        running via CRI-O for this benchmark yet)."
