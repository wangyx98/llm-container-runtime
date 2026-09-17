#!/bin/bash
# 不加 set -e：容器/任务可能本来就不存在，允许命令失败

CONTAINER="bench72392812"
WORK_DIR="/tmp/bench72392812"

echo "[cleanup] killing task (SIGKILL)..."
sudo ctr task kill -s SIGKILL "$CONTAINER" 2>/dev/null || true
sleep 1

echo "[cleanup] deleting task..."
sudo ctr task delete "$CONTAINER" 2>/dev/null || true

echo "[cleanup] deleting container..."
sudo ctr container delete "$CONTAINER" 2>/dev/null || true

echo "[cleanup] removing host work dir (config + log files)..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
echo "[cleanup] (gVisor/runsc packages are left installed, same as other"
echo "[cleanup]  cases leave pulled images in place -- only this case's"
echo "[cleanup]  own artifacts are removed.)"
