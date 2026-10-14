#!/bin/bash
# Reference: a version 3 configuration reads the registry settings of the CRI plugin under io.containerd.cri.v1.images, not under the id io.containerd.grpc.v1.cri of versions 1 and 2, so the
# mirror with the http endpoint was never applied and the pull went to https://. The supported way is a config_path directory with one hosts.toml per registry (HOST:PORT) that names the http
# server; the old registry tables are removed. The credentials stay out of the node: the kubelet (the evaluator) passes them with every pull, and the Docker Hub key in the old tables
# was never the registry's. containerd reads its configuration at start: restart.
set -e

HOST=registry.bench79305194.test
PORT=35791
CONF=/etc/bench79305194/config.toml
HOSTS_DIR=/etc/bench79305194/certs.d

sudo mkdir -p "$HOSTS_DIR/$HOST:$PORT"
sudo tee "$HOSTS_DIR/$HOST:$PORT/hosts.toml" >/dev/null <<TOML
server = "http://$HOST:$PORT"

[host."http://$HOST:$PORT"]
  capabilities = ["pull", "resolve"]
TOML
sudo python3 - "$CONF" "$HOSTS_DIR" <<'PY'
import re, sys
conf, hosts_dir = sys.argv[1:3]
text = open(conf).read()
text = text[:text.index("# The registry settings, copied from")].rstrip("\n") + "\n"
text += '\n[plugins."io.containerd.cri.v1.images".registry]\n  config_path = "%s"\n' % hosts_dir
open(conf, "w").write(text)
PY
sudo systemctl restart bench79305194-containerd.service
sudo cat "$CONF" | tail -4
