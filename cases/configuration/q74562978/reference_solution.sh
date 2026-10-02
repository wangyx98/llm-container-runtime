#!/bin/bash
# Reference fix: containerd's CRI already reads per-registry settings from
# /etc/containerd/certs.d (config_path); the directory named after the
# registry (host:port) holds a hosts.toml that says which URL to use for it.
# Without one, containerd assumes https:// for any host that is not loopback.
# Declaring the registry's real, plain-HTTP URL is enough; hosts.toml is read on
# every pull, so no restart is needed.
set -e

sudo mkdir -p "/etc/containerd/certs.d/registry.bench74562978.test:25562"
sudo tee "/etc/containerd/certs.d/registry.bench74562978.test:25562/hosts.toml" >/dev/null <<'HEOF'
server = "http://registry.bench74562978.test:25562"

[host."http://registry.bench74562978.test:25562"]
  capabilities = ["pull", "resolve"]
HEOF
