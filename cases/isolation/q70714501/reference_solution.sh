#!/bin/bash
set -e

TESTUSER="testuser"
GROUP="crictl-users"
CONFIG="/etc/containerd/config.toml"
SOCK="/run/containerd/containerd.sock"

echo "[solution] creating a dedicated group for crictl access..."
sudo groupadd -f "$GROUP"

echo "[solution] adding $TESTUSER to $GROUP (supplementary group, not primary)..."
sudo usermod -aG "$GROUP" "$TESTUSER"

GID=$(getent group "$GROUP" | cut -d: -f3)

echo "[solution] configuring containerd's grpc socket to be group-owned by gid=$GID..."
sudo python3 - "$CONFIG" "$GID" <<'PYEOF'
import re
import sys

path, gid = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()

if re.search(r'(?ms)^\[grpc\].*?^\s*gid\s*=', text):
    text = re.sub(
        r'(?ms)(^\[grpc\].*?^\s*gid\s*=\s*)\d+',
        lambda m: m.group(1) + gid,
        text,
        count=1,
    )
else:
    text = re.sub(r'(?m)^\[grpc\]', f'[grpc]\n  gid = {gid}', text, count=1)

with open(path, 'w') as f:
    f.write(text)
PYEOF

echo "[solution] restarting containerd to apply new socket ownership..."
sudo systemctl restart containerd
sleep 2

echo "[solution] done. New socket ownership/permissions:"
ls -l "$SOCK"
