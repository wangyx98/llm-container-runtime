#!/bin/bash
set -e

CONTAINER="bench73631968"
WORK_DIR="/tmp/bench73631968"
BAD_PORT=18973
IMAGE="docker.io/library/busybox:1.36"

echo "[solution] port is already taken by another host service we must not touch --"
echo "[solution] picking a free host port instead and re-publishing the container there..."

GOOD_PORT=$(python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('0.0.0.0', 0))
print(s.getsockname()[1])
s.close()
")
echo "[solution] chosen free port: $GOOD_PORT"

echo "[solution] removing the old (misconfigured) container..."
sudo nerdctl rm -f "$CONTAINER" < /dev/null > /dev/null 2>&1

echo "[solution] re-running it published to the free port..."
sudo nerdctl run -d --name "$CONTAINER" \
    -p "${GOOD_PORT}:80" \
    -v "$WORK_DIR/container_site:/www" \
    "$IMAGE" busybox httpd -f -p 80 -h /www \
    < /dev/null > /dev/null 2>&1

echo "[solution] done. Container republished on port $GOOD_PORT (port $BAD_PORT's"
echo "[solution] pre-existing service was never touched)."
