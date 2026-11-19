#!/bin/bash
set -e

W="/tmp/bench76379942"
CONF="/var/lib/bench76379942/etc/containerd.toml"
PROPS="/var/lib/bench76379942/nexus/etc/nexus.properties"

# Nexus' Docker connector: the host and port of its configuration (and what ss shows), not the port of the image names
HOST=$(sed -n 's/^nexus\.docker\.docker-all\.http\.host=//p' "$PROPS")
PORT=$(sed -n 's/^nexus\.docker\.docker-all\.http\.port=//p' "$PROPS")
OLD=$(grep -o 'http://[^"]*' "$CONF" | head -1)          # the engineer's mirror endpoint, host:port where nothing listens
echo "[solution] Nexus listens on $HOST:$PORT (plain HTTP); the mirror of docker.io points at $OLD"
ss -ltn | grep -q "$HOST:$PORT" || { echo "[solution] nothing listens on $HOST:$PORT"; exit 1; }

echo "[solution] docker.io -> Nexus' real connector, and the explicit name ${OLD#http://} (the thread's port) -> the same connector; then containerd has to be restarted..."
sudo sed -i "s#endpoint = \[\"$OLD\"\]#endpoint = [\"http://$HOST:$PORT\"]#" "$CONF"
sudo tee -a "$CONF" >/dev/null <<TOML
  [plugins."io.containerd.cri.v1.images".registry.mirrors."${OLD#http://}"]
    endpoint = ["http://$HOST:$PORT"]
TOML
sudo /var/lib/bench76379942/bin/containerdctl restart

echo "[solution] both names pull now:"
"$W/bin/node-crictl" pull bench76379942/web:1.0 | tail -1
"$W/bin/node-crictl" pull "${OLD#http://}/bench76379942/api:1.0" | tail -1
