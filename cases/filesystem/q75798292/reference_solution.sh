#!/bin/bash
set -e

CONTAINER="bench75798292"
HOST_FILE="/tmp/bench75798292/test.txt"

echo "[solution] locating container task PID..."
PID=$(sudo ctr tasks ls | grep "$CONTAINER" | awk '{print $2}')

if [ -z "$PID" ]; then
    echo "[solution] ERROR: could not find running task PID for $CONTAINER"
    exit 1
fi

echo "[solution] found PID=$PID, writing via /proc/$PID/root ..."
sudo mkdir -p "/proc/$PID/root/data"
sudo cp "$HOST_FILE" "/proc/$PID/root/data/test.txt"

echo "[solution] done. File written into container namespace via host-side proc root."

# --- 备选方案（原SO作者的做法，依赖具体containerd路径布局，仅作参考） ---
# ROOTFS="/run/containerd/io.containerd.runtime.v2.task/default/$CONTAINER/rootfs"
# sudo test -d "$ROOTFS"
# sudo mkdir -p "$ROOTFS/data"
# sudo cp "$HOST_FILE" "$ROOTFS/data/test.txt"
