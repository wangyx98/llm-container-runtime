#!/bin/bash
# Reference solution: the node asks for the image at the registry's address but the mirror entry for "10.68.63.45:5050" sends the request to https://10.68.63.45, i.e. port 443, where the GitLab web application
# (not the registry) answers: every /v2/... path is redirected to the sign-in page, a 200 text/html whose bytes differ at each request (a CSRF token). containerd takes the page's sha256 for the manifest's digest
# (the answer has no Docker-Content-Digest), asks for it by that digest, is given another page and refuses: "failed commit on ref unknown-sha256:...: unexpected commit digest". The endpoint needs the
# registry's port (https://10.68.63.45:5050); the configuration is read when containerd starts, so containerd is restarted. The kubelet's pull secret is the deploy token.
set -e
LIB="/var/lib/bench68630845"
ADDR="10.68.63.45"
sudo sed -i "s|endpoint = \[\"https://$ADDR\"\]|endpoint = [\"https://$ADDR:5050\"]|" "$LIB/etc/containerd.toml"
grep -n "endpoint" "$LIB/etc/containerd.toml"
sudo "$LIB/bin/nodectl" restart
sudo "$LIB/bin/crictl" pull --creds 'gitlab+deploy-token-1:k8s-pull-secret' "$ADDR:5050/lab-user/webapp/nginx:v1"
sudo "$LIB/bin/crictl" images
