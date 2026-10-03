#!/bin/bash
set -e

NAME="bench66478456"
IMAGE="docker.io/library/bench66478456:latest"
DATA="/tmp/bench66478456/data"

echo "[solution] ctr only applies --uidmap when --gidmap is given as well (it reads both"
echo "[solution] together); with only --uidmap it silently starts a plain container whose"
echo "[solution] root is the host's root. A running container's namespaces cannot be changed,"
echo "[solution] so the engineer's container has to be removed and started again with both maps."
sudo ctr tasks delete --force "$NAME" 2>/dev/null || true
sudo ctr containers delete "$NAME"

sudo ctr run -d \
    --uidmap 0:5000:4999 \
    --gidmap 0:5000:4999 \
    --mount "type=bind,src=$DATA,dst=/data,options=rbind:rw" \
    "$IMAGE" "$NAME" </dev/null

echo "[solution] giving the container a moment to start and write /data/inside.txt..."
sleep 2

echo "[solution] done."
