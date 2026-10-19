#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench71499683"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
REG_CONF="/etc/containers/registries.conf.d/99-$CASE_ID.conf"

echo "[cleanup] removing the pods of this case (and their containers) from CRI-O..."
for POD in $(sudo crictl pods --name "^$CASE_ID-" -q 2>/dev/null); do
    sudo timeout 60 crictl rmp -f "$POD" >/dev/null 2>&1
done
sudo rm -rf /var/log/pods/"$CASE_ID"-*

echo "[cleanup] removing the images of this case: by name, and every image made since setup recorded what existed (CRI-O and Podman share the store)..."
for REF in $(sudo podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep "^registry\.$CASE_ID\.invalid/"); do
    sudo podman rmi -f "$REF" >/dev/null 2>&1    # by name: an image that has other names only loses this one
done
if sudo test -f "$STATE_DIR/images.base"; then
    for ID in $(sudo podman images -aq --no-trunc 2>/dev/null | sed 's/^sha256://' | sort -u); do
        sudo grep -qx "$ID" "$STATE_DIR/images.base" || sudo podman rmi -f "$ID" >/dev/null 2>&1
    done
fi

echo "[cleanup] removing the stores and files of the oracle, the work dir and the files of the lab (the downloaded Go in /var/cache/$CASE_ID stays)..."
for M in $(findmnt -rn -o TARGET 2>/dev/null | grep "^$WORK_DIR" | sort -r); do sudo umount -l "$M" >/dev/null 2>&1; done
sudo rm -rf "$WORK_DIR" /tmp/"$CASE_ID"-* "$LIB_BASE" "$REG_CONF"

echo "[cleanup] done. Environment reset to clean state."
