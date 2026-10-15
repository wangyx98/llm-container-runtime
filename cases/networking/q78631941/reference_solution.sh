#!/bin/bash
set -e

CASE_ID="bench78631941"
LIB="/var/lib/$CASE_ID"
APP_DIR="/tmp/$CASE_ID/app"
SOCK="/run/$CASE_ID/containerd.sock"
CTR="sudo ctr -a $SOCK -n $CASE_ID"

# 1. the snapshotter fetches from the registry with its own configuration, not the client's: tell it that this registry is plain HTTP (the key is the registry as it is written in the image
#    reference, the mirror's host is a URL), and restart it (the configuration is read at start)
sudo tee -a "$LIB/soci/config.toml" >/dev/null <<'EOT'

[[resolver.host."10.78.63.2:5000".mirrors]]
host = "http://10.78.63.2:5000"
insecure = true
EOT
sudo "$LIB/bin/soci-service" restart

# 2. the container that is running was made before: remove it and its image, then pull again and make a new one (the image was unpacked locally, a new pull of it would not be lazy)
$CTR tasks kill -s KILL lazy >/dev/null 2>&1 || true
for _ in $(seq 1 20); do $CTR tasks delete lazy >/dev/null 2>&1 && break; sleep 0.5; done
$CTR containers delete lazy >/dev/null 2>&1 || true
$CTR images rm --sync 10.78.63.2:5000/app:seed >/dev/null 2>&1 || true
(cd "$APP_DIR" && GOFLAGS=-mod=mod go build -o lazyrun .)
sudo "$APP_DIR/lazyrun" --address "$SOCK" --namespace "$CASE_ID" --name lazy --ref 10.78.63.2:5000/app:seed --snapshotter soci
