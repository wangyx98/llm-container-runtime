#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench73029815"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

echo "[cleanup] removing the pods of this case (and their containers) from CRI-O..."
for POD in $(sudo crictl pods --name "^$CASE_ID-" -q 2>/dev/null); do
    sudo timeout 60 crictl rmp -f "$POD" >/dev/null 2>&1
done
sudo rm -rf /var/log/pods/"$CASE_ID"-*

echo "[cleanup] removing the Podman container of this case and every Podman image made since setup recorded what existed..."
sudo podman kill "$CASE_ID-native" >/dev/null 2>&1    # a "sleep" as process 1 ignores SIGTERM: without the kill, rm -f waits ten seconds
sudo podman rm -f "$CASE_ID-native" >/dev/null 2>&1
if sudo test -f "$STATE_DIR/images.base"; then
    for ID in $(sudo podman images -aq --no-trunc 2>/dev/null | sort -u); do
        sudo grep -qx "$ID" "$STATE_DIR/images.base" || sudo podman rmi -f "$ID" >/dev/null 2>&1
    done
fi
for REF in $(sudo podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep "^localhost/$CASE_ID/"); do
    sudo podman rmi -f "$REF" >/dev/null 2>&1    # by name: an image that has other names (the base image under a wrong tag) only loses this one
done

echo "[cleanup] removing the work dir and temporary files..."
sudo rm -rf "$WORK_DIR" /tmp/"$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
