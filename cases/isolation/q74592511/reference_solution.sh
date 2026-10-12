#!/bin/bash
set -e

DEV="bench74592511-dev"
GROUP="criusers"
CONFIG="/etc/containerd/config.toml"
SOCK="/run/containerd/containerd.sock"

echo "[solution] creating a dedicated group and putting only $DEV in it..."
sudo groupadd -f "$GROUP"
sudo usermod -aG "$GROUP" "$DEV"
GID=$(getent group "$GROUP" | cut -d: -f3)

echo "[solution] making the socket belong to that group (gid=$GID) through containerd's own config, so it survives restarts..."
sudo python3 - "$CONFIG" "$GID" <<'PYEOF'
import re
import sys

path, gid = sys.argv[1], sys.argv[2]
text = open(path).read()
if re.search(r'(?ms)^\[grpc\].*?^\s*gid\s*=', text):
    text = re.sub(r'(?ms)(^\[grpc\].*?^\s*gid\s*=\s*)\d+', lambda m: m.group(1) + gid, text, count=1)
else:
    text = re.sub(r'(?m)^\[grpc\]', '[grpc]\n  gid = ' + gid, text, count=1)
open(path, 'w').write(text)
PYEOF

echo "[solution] restarting containerd..."
sudo systemctl restart containerd || { sudo systemctl reset-failed containerd; sleep 8; sudo systemctl restart containerd; }
for _ in $(seq 1 40); do
    [ -S "$SOCK" ] && sudo crictl info >/dev/null 2>&1 && break
    sleep 0.5
done
ls -l "$SOCK"
sudo -n -u "$DEV" -H crictl info >/dev/null && echo "[solution] $DEV runs crictl without sudo."
