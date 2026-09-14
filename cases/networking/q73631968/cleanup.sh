#!/bin/bash
# no 'set -e': allow best-effort cleanup even if some pieces are already gone

CONTAINER="bench73631968"
WORK_DIR="/tmp/bench73631968"
BAD_PORT=18973

echo "[cleanup] removing the container..."
sudo nerdctl rm -f "$CONTAINER" 2>/dev/null || true

echo "[cleanup] stopping the dummy host service on port $BAD_PORT..."
if [ -f "$WORK_DIR/.dummy_pid" ]; then
    kill "$(cat "$WORK_DIR/.dummy_pid")" 2>/dev/null || true
fi
pkill -f "http.server $BAD_PORT" 2>/dev/null || true

echo "[cleanup] removing work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
