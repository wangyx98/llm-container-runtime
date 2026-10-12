#!/bin/bash
set -e

CASE_ID="bench74592511"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_BASE="/var/lib/$CASE_ID"          # what the cleanup needs to give the host back as it was (root-only)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the helpers of the oracle and their hashes
CONFIG="/etc/containerd/config.toml"
CRICTL_CONF="/etc/crictl.yaml"
SOCK="/run/containerd/containerd.sock"
DEV="bench74592511-dev"               # the user who has to get crictl
OTHER="bench74592511-other"           # a second user who has to stay out

restart_containerd() {   # systemd refuses a 6th start within 10 s: reset the counter and try again
    sudo systemctl restart containerd 2>/dev/null && return 0
    sudo systemctl reset-failed containerd 2>/dev/null; sleep 8
    sudo systemctl restart containerd
}

echo "[setup] checking containerd, ctr, crictl, systemctl and python3 are installed..."
for b in containerd ctr crictl systemctl python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] keeping what the cleanup has to give back: the host's containerd config, crictl config and groups..."
sudo mkdir -p "$LIB_BASE"
sudo chmod 700 "$LIB_BASE"
if [ -e "$CONFIG" ]; then sudo cp -p "$CONFIG" "$LIB_BASE/config.toml.orig"; else sudo touch "$LIB_BASE/config.toml.absent"; fi
if [ -e "$CRICTL_CONF" ]; then sudo cp -p "$CRICTL_CONF" "$LIB_BASE/crictl.yaml.orig"; else sudo touch "$LIB_BASE/crictl.yaml.absent"; fi
getent group | cut -d: -f1 | sudo tee "$LIB_BASE/groups.before" >/dev/null

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
cp "$CASE_DIR"/helpers/{mkimg.py,verify.py} "$STATE_DIR/"
(cd "$STATE_DIR" && sha256sum mkimg.py verify.py | awk '{print $1}' > helpers.sha)

echo "[setup] pointing crictl at the containerd socket (/etc/crictl.yaml)..."
{
    echo "runtime-endpoint: unix://$SOCK"
    echo "image-endpoint: unix://$SOCK"
    echo "timeout: 10"
    echo "debug: false"
} | sudo tee "$CRICTL_CONF" >/dev/null

echo "[setup] writing the explicit default containerd config (no [grpc] gid) and restarting containerd: the socket is root:root 0660..."
sudo mkdir -p /etc/containerd
containerd config default | sudo tee "$CONFIG" >/dev/null
restart_containerd
for _ in $(seq 1 80); do
    [ -S "$SOCK" ] && sudo crictl info >/dev/null 2>&1 && break
    sleep 0.5
done
sudo systemctl reset-failed containerd 2>/dev/null || true   # a fresh start-limit counter for the solution
sudo crictl info >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI of containerd does not answer even for root"; exit 1; }

echo "[setup] creating the two users (no special groups, no sudo): $DEV and $OTHER..."
for u in "$DEV" "$OTHER"; do
    id "$u" >/dev/null 2>&1 || sudo useradd -m -s /bin/bash "$u"
done

echo "[setup] done. The socket:"
ls -l "$SOCK"
