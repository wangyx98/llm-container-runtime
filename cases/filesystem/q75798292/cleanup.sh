#!/bin/bash
# 不加 set -e，因为容器/任务可能本来就不存在，允许命令失败

CONTAINER="bench75798292"
HOST_DIR="/tmp/bench75798292"

echo "[cleanup] killing task (SIGKILL, in case SIGTERM doesn't work on sleep infinity)..."
sudo ctr task kill -s SIGKILL "$CONTAINER" 2>/dev/null || true
sleep 1

echo "[cleanup] deleting task..."
sudo ctr task delete "$CONTAINER" 2>/dev/null || true

echo "[cleanup] deleting container..."
sudo ctr container delete "$CONTAINER" 2>/dev/null || true

echo "[cleanup] removing host test dir..."
sudo rm -rf "$HOST_DIR"

echo "[cleanup] done. Environment reset to clean state."
