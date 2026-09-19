#!/bin/bash
# no 'set -e': the pod/container may legitimately not exist yet, and
# commands here are allowed to fail without aborting cleanup.

POD_NAME="bench69295491-pod"
CONTAINER_NAME="bench69295491"
WORK_DIR="/tmp/bench69295491"

echo "[cleanup] stopping + removing any container(s) named '$CONTAINER_NAME'..."
for c in $(sudo crictl ps -a --name "$CONTAINER_NAME" -q 2>/dev/null); do
    sudo crictl stop "$c" 2>/dev/null || true
    sudo crictl rm -f "$c" 2>/dev/null || true
done

echo "[cleanup] stopping + removing any pod sandbox(es) named '$POD_NAME'..."
for p in $(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null); do
    sudo crictl stopp "$p" 2>/dev/null || true
    sudo crictl rmp -f "$p" 2>/dev/null || true
done

echo "[cleanup] removing work dir (host dir + JSON configs)..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
