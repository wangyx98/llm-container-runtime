#!/bin/bash
set -e

CONTAINER="bench74317699"
BUNDLE_DIR="/tmp/bench74317699/bundle"

echo "[solution] 'runc start' only transitions a container from 'created' to"
echo "[solution] 'running' -- it refuses a container that has already stopped."
echo "[solution] Deleting the stopped container's runtime state (this does NOT"
echo "[solution] touch the bundle/rootfs on disk)..."
sudo runc delete "$CONTAINER"

echo "[solution] re-creating and starting the container from the SAME bundle..."
sudo runc run --bundle "$BUNDLE_DIR" --detach "$CONTAINER"

echo "[solution] done."
