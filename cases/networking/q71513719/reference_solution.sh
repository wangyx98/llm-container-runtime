#!/bin/bash
set -e

NAME="bench71513719"
IMAGE="docker.io/library/bench71513719:latest"

echo "[solution] ctr has no -p/--publish option (the mapping a Docker user expects is something"
echo "[solution] nerdctl or CNI's portmap plugin provides). The container started by plain 'ctr run'"
echo "[solution] has a network namespace of its own with only a loopback device, and a running"
echo "[solution] container's namespaces cannot be changed. So remove it and start it again in the"
echo "[solution] host's network namespace (--net-host): its server then listens on host port 8085."
sudo ctr tasks kill -s SIGKILL "$NAME" 2>/dev/null || true
sudo ctr tasks delete --force "$NAME" 2>/dev/null || true
sudo ctr containers delete "$NAME"

sudo ctr run -d --net-host "$IMAGE" "$NAME" </dev/null

echo "[solution] waiting until the host gets an answer on port 8085..."
for _ in $(seq 1 20); do
    curl -fsS --noproxy '*' --max-time 2 "http://127.0.0.1:8085/" >/dev/null 2>&1 && break
    sleep 0.5
done

echo "[solution] done."
