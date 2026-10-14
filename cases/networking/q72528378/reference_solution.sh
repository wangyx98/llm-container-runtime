#!/bin/bash
# Reference: containerd looks a registry up under the host of the REFERENCE: registry.bench72528378.test/calculator/app2:new has no port, so the key is registry.bench72528378.test; the
# mirror and config tables under registry.bench72528378.test:80 never match it, and the pull goes to the default https://registry.bench72528378.test:443 (connection refused). The supported way
# (deprecated tables replaced, as containerd's docs/hosts.md says) is a config_path directory with one directory per registry host, named like the reference's host (no port), with a
# hosts.toml that names the http server; the legacy tables are removed (containerd refuses a configuration with both: its CRI plugin does not load). containerd reads its configuration at
# start: restart. The reference stays as it is.
set -e

HOST=registry.bench72528378.test
CONF=/etc/bench72528378/config.toml
HOSTS_DIR=/etc/bench72528378/certs.d

sudo mkdir -p "$HOSTS_DIR/$HOST"
sudo tee "$HOSTS_DIR/$HOST/hosts.toml" >/dev/null <<TOML
server = "http://$HOST"

[host."http://$HOST"]
  capabilities = ["pull", "resolve"]
TOML
sudo python3 - "$CONF" "$HOSTS_DIR" <<'PY'
import re, sys
conf, hosts_dir = sys.argv[1:3]
text = open(conf).read()
i = text.index('  [plugins."io.containerd.grpc.v1.cri".registry]')
text = text[:i].rstrip("\n") + '\n\n  [plugins."io.containerd.grpc.v1.cri".registry]\n    config_path = "%s"\n' % hosts_dir
open(conf, "w").write(text)
PY
sudo systemctl restart bench72528378-containerd.service
sudo tail -5 "$CONF"
