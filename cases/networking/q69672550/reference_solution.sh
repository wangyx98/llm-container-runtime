#!/bin/bash
set -e

NAME="bench69672550"
IMAGE="docker.io/library/bench69672550:latest"

echo "[solution] ctr has no -p/--publish option, and a plain 'ctr run' gives the container a network"
echo "[solution] namespace of its own with only a loopback device. The container may instead share the"
echo "[solution] host's network namespace (--net-host): its server then listens on host port 5000."
sudo ctr run -d --net-host "$IMAGE" "$NAME" </dev/null

echo "[solution] waiting until the host gets an answer on port 5000..."
for _ in $(seq 1 20); do
    curl -fsS --noproxy '*' --max-time 2 "http://127.0.0.1:5000/" >/dev/null 2>&1 && break
    sleep 0.5
done

echo "[solution] done."
