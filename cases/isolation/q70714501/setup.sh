#!/bin/bash
set -e

TESTUSER="testuser"
CONFIG="/etc/containerd/config.toml"
SOCK="/run/containerd/containerd.sock"

echo "[setup] writing explicit default containerd config (so it's editable/resettable)..."
sudo mkdir -p /etc/containerd
containerd config default | sudo tee "$CONFIG" > /dev/null

echo "[setup] restarting containerd with default (root-only) socket perms..."
sudo systemctl restart containerd
sleep 2

echo "[setup] pointing crictl at the containerd CRI socket..."
{
    echo "runtime-endpoint: unix://$SOCK"
    echo "image-endpoint: unix://$SOCK"
    echo "timeout: 2"
    echo "debug: false"
} | sudo tee /etc/crictl.yaml > /dev/null

echo "[setup] creating non-root test user ($TESTUSER) with no special group membership..."
if ! id "$TESTUSER" >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash "$TESTUSER"
fi

echo "[setup] done. Current socket ownership/permissions:"
ls -l "$SOCK"
