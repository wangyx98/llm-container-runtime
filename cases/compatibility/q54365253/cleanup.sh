#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench54365253"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

echo "[cleanup] removing the containers of this case (runc keeps their state in its own root $RUN_BASE)..."
for ID in $(sudo runc --root "$RUN_BASE" list -q 2>/dev/null); do
    sudo timeout 60 runc --root "$RUN_BASE" delete -f "$ID" >/dev/null 2>&1
done

echo "[cleanup] removing the work dir, the lab and the state of runc (mounts below them first)..."
for M in $(findmnt -rn -o TARGET 2>/dev/null | grep -e "^$WORK_DIR" -e "^$LIB_BASE" | sort -r); do sudo umount -l "$M" >/dev/null 2>&1; done
sudo rm -rf "$WORK_DIR" /tmp/"$CASE_ID"-* "$LIB_BASE" "$RUN_BASE"
sudo find /sys/fs/cgroup -maxdepth 3 -type d -name "$CASE_ID-*" -exec rmdir {} \; >/dev/null 2>&1

echo "[cleanup] done. Environment reset to clean state."
