#!/bin/bash
set -e

CONTAINER="bench72392812"
IMAGE="docker.io/library/alpine:3.20"
RUNSC_CONF="/tmp/bench72392812/runsc.toml"

echo "[solution] 'ctr' has no idea about the CRI/dockerd config that maps a"
echo "[solution] named runtime (like Docker's 'runsc' entry in daemon.json)"
echo "[solution] to a set of runsc flags. When calling 'ctr run' directly,"
echo "[solution] the runsc.toml config must be handed to the shim explicitly"
echo "[solution] via --runtime-config-path, otherwise it's silently ignored"
echo "[solution] and runsc starts with default (non-debug) settings."
sudo ctr run -d \
    --runtime io.containerd.runsc.v1 \
    --runtime-config-path "$RUNSC_CONF" \
    "$IMAGE" "$CONTAINER" sleep infinity

echo "[solution] giving the sandbox a moment to finish booting and flush its boot/create logs..."
sleep 2

echo "[solution] done."
