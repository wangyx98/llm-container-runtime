#!/bin/bash
# Reference: the workers do not trust the registry's CA where CRI-O (containers/image) looks for it. CRI-O reads /etc/containers/certs.d/HOST:PORT/ca.crt (or /etc/docker/certs.d/HOST:PORT/ca.crt),
# keyed by host AND port: worker1 has the CA in /etc/crio/certs.d (which nothing reads), worker2 under HOST without the port. The CA goes into each worker's own
# etc/containers/certs.d/HOST:PORT; the credentials (the imagePullSecret) were never the problem, the verification stays on, the master is left alone. certs.d is read at every pull: no restart needed.
set -e

HOST=registry.bench71671179.test
PORT=35751
CA=/etc/bench71671179/registry-ca.crt

for n in worker1 worker2; do
    d=/var/lib/bench71671179/$n/etc/containers/certs.d
    sudo mkdir -p "$d/$HOST:$PORT"
    sudo cp "$CA" "$d/$HOST:$PORT/ca.crt"
done
sudo rm -rf /var/lib/bench71671179/worker2/etc/containers/certs.d/$HOST
find /var/lib/bench71671179/*/etc -name '*.crt' | sort
