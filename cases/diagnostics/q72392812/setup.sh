#!/bin/bash
set -e

CONTAINER="bench72392812"
IMAGE="docker.io/library/alpine:3.20"
WORK_DIR="/tmp/bench72392812"
LOG_DIR="$WORK_DIR/runsc-logs"
RUNSC_CONF="$WORK_DIR/runsc.toml"

echo "[setup] ensuring gVisor (runsc + containerd-shim-runsc-v1) is installed..."
if ! command -v runsc >/dev/null 2>&1 || ! command -v containerd-shim-runsc-v1 >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq apt-transport-https ca-certificates curl gnupg

    curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" \
        | sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq runsc
fi

echo "[setup] confirming runsc + shim binaries are on PATH..."
command -v runsc
command -v containerd-shim-runsc-v1

echo "[setup] removing any leftover container/task from a previous run (idempotency)..."
sudo ctr task kill -s SIGKILL "$CONTAINER" 2>/dev/null || true
sleep 1
sudo ctr task delete "$CONTAINER" 2>/dev/null || true
sudo ctr container delete "$CONTAINER" 2>/dev/null || true

echo "[setup] resetting work dir and creating an EMPTY log directory..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$LOG_DIR"

echo "[setup] writing runsc debug-logging config to $RUNSC_CONF ..."
cat > "$RUNSC_CONF" <<EOF
[runsc_config]
  debug = "true"
  debug-log = "$LOG_DIR/"
  strace = "true"
EOF
cat "$RUNSC_CONF"

echo "[setup] pulling image..."
sudo ctr images pull "$IMAGE"

echo "[setup] done. gVisor is installed, config is in place, log dir is empty, container does not exist yet."
