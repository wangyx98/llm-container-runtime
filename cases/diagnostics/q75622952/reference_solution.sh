#!/bin/bash
# Reference solution: the node asked the registry for "/k8mtest/k8m/manifests/v1.0" - without /v2 - because the mirror's endpoint ends in a slash ("https://<registry>/"): containerd 1.6's CRI takes the path
# of the endpoint as the root of the registry API and puts /v2 there only when the path is empty ("https://<registry>") or "/v2/". A path outside /v2/ is the portal page of Harbor (200, text/html), whose
# bytes containerd takes for the manifest. The endpoint without the slash, a restart of containerd (the configuration is read at its start) and a pull; the CA file, the account and the verification stay.
set -e
LIB="/var/lib/bench75622952"
HP="10.75.62.29:8443"
sudo sed -i "s|endpoint = \[\"https://$HP/\"\]|endpoint = [\"https://$HP\"]|" "$LIB/etc/containerd.toml"
grep -n "endpoint" "$LIB/etc/containerd.toml"
sudo "$LIB/bin/nodectl" restart
sudo "$LIB/bin/crictl" pull "$HP/k8mtest/k8m:v1.0"
sudo "$LIB/bin/crictl" images
