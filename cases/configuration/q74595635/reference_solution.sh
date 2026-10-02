#!/bin/bash
# Reference fix: the CRI plugin only reads per-registry settings from a
# directory when config_path is set in /etc/containerd/config.toml (it is empty
# by default), and the mirror itself is declared in a hosts.toml under that
# directory, named after the registry (docker.io). Changing config.toml needs a
# containerd restart.
set -e

# set every empty config_path (the CRI registry one is among them), whatever
# the config version / quote style is
sudo sed -i -E "s|^([[:space:]]*config_path[[:space:]]*=[[:space:]]*)(''\|\"\")|\1'/etc/containerd/certs.d'|" /etc/containerd/config.toml

sudo mkdir -p /etc/containerd/certs.d/docker.io
sudo tee /etc/containerd/certs.d/docker.io/hosts.toml >/dev/null <<'HEOF'
server = "https://registry-1.docker.io"

[host."http://127.0.0.1:25635"]
  capabilities = ["pull", "resolve"]
HEOF

sudo systemctl restart containerd
for _ in $(seq 1 20); do
    [ -S /run/containerd/containerd.sock ] && sudo crictl info >/dev/null 2>&1 && break
    sleep 0.5
done
