#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a container already gone), and every command here may fail without aborting the cleanup.

CASE_ID="bench66547508"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

echo "[cleanup] deleting this case's runc containers (the main one and the control ones: every ID of runc that starts with $CASE_ID)..."
for id in $(sudo runc list -q 2>/dev/null | grep "^$CASE_ID"); do
    [[ "$id" =~ ^bench66547508[a-z0-9-]*$ ]] || continue
    sudo timeout -k 3 30 runc delete -f "$id" >/dev/null 2>&1 || true
    sudo rm -rf "/run/runc/$id"                    # runc's state of the container (explicit path: no glob that a user who is not root cannot expand)
done

echo "[cleanup] stopping the nonce service and what a solution may have left running..."
for pid in $(pgrep -x python3 2>/dev/null); do
    sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$WORK_DIR" && sudo kill -9 "$pid" 2>/dev/null || true
done
for pid in $(pgrep -x app 2>/dev/null); do     # a container's program outlives a failed delete: it is ours if its cgroup path has the name of the case
    sudo grep -q "$CASE_ID" "/proc/$pid/cgroup" 2>/dev/null && sudo kill -9 "$pid" 2>/dev/null || true
done
sleep 0.5

echo "[cleanup] removing the cgroup directories that are left, the bundle and the work dir..."
sudo find /sys/fs/cgroup -maxdepth 8 -depth -type d -name "$CASE_ID*" -exec rmdir {} \; 2>/dev/null
sudo rm -rf --one-file-system "$LIB_BASE"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-* "/tmp/$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
