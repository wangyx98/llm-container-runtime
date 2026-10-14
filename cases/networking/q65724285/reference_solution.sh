#!/bin/bash
# Reference: the two entrances read different things, so there are two fixes.
# ctr (the client of the question) never reads config.toml: its pulls go to https://HOST:5000 unless the command names a hosts directory (--hosts-dir DIR, one directory named HOST:PORT with a
# hosts.toml that gives the http server) or says --plain-http; the check uses the hosts directory, so the directory is created.
# The CRI (the kubelet) reads config.toml: skip_verify there only skips the certificate check, it does not turn https into http, and the mirror's endpoint is https://HOST:5000, so the CRI also
# speaks TLS to the plain HTTP registry. The endpoint becomes http://HOST:5000; containerd reads its configuration at start: restart.
set -e

HOST=registry.bench65724285.test
PORT=5000
CONF=/etc/bench65724285/config.toml
HOSTS_DIR=/etc/bench65724285/certs.d

sudo mkdir -p "$HOSTS_DIR/$HOST:$PORT"
sudo tee "$HOSTS_DIR/$HOST:$PORT/hosts.toml" >/dev/null <<TOML
server = "http://$HOST:$PORT"

[host."http://$HOST:$PORT"]
  capabilities = ["pull", "resolve"]
TOML
sudo sed -i "s#endpoint = \[\"https://$HOST:$PORT\"\]#endpoint = [\"http://$HOST:$PORT\"]#" "$CONF"
sudo systemctl restart bench65724285-containerd.service
sudo grep -n "endpoint" "$CONF"
