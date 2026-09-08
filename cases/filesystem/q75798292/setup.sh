#!/bin/bash
set -e

CONTAINER="bench75798292"
IMAGE="docker.io/library/alpine:3.20"
HOST_DIR="/tmp/bench75798292"

echo "[setup] pulling image..."
sudo ctr images pull "$IMAGE"

echo "[setup] creating host test file..."
sudo mkdir -p "$HOST_DIR"
echo "SO75798292_CONTAINERD_COPY_TEST" | sudo tee "$HOST_DIR/test.txt" > /dev/null
sha256sum "$HOST_DIR/test.txt"

echo "[setup] creating container..."
sudo ctr container create "$IMAGE" "$CONTAINER" sleep infinity

echo "[setup] starting task..."
sudo ctr task start -d "$CONTAINER"

sleep 1
sudo ctr tasks ls | grep "$CONTAINER"

echo "[setup] recording initial task PID as container identity fingerprint..."
INITIAL_PID=$(sudo ctr tasks ls | grep "$CONTAINER" | awk '{print $2}')
echo "$INITIAL_PID" | sudo tee "$HOST_DIR/.initial_pid" > /dev/null
echo "[setup] initial PID recorded: $INITIAL_PID"

echo "[setup] done."
