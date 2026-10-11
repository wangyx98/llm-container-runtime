#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a container already gone), and every command here may fail without aborting the cleanup.

CASE_ID="bench64071782"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

echo "[cleanup] deleting this case's runc containers (the IDs the lab recorded, and any other container of runc whose ID starts with $CASE_ID-)..."
IDS=$( { cat "$STATE_DIR/ids.txt" 2>/dev/null; sudo runc list -q 2>/dev/null | grep "^$CASE_ID-"; } | sort -u)
for id in $IDS; do
    [[ "$id" =~ ^bench64071782-[a-z0-9-]+$ ]] || continue
    sudo timeout -k 3 30 runc delete -f "$id" >/dev/null 2>&1 || true
    sudo rm -rf "/run/runc/$id"                    # runc's state of the container (explicit path: no glob that a user who is not root cannot expand)
done

# a container's processes outlive a failed delete: they are ours if their cgroup path has the name of the case (the first two containers have a parent of that name, the third an ID that has it)
for pid in $(pgrep -x app 2>/dev/null); do
    sudo grep -q "$CASE_ID" "/proc/$pid/cgroup" 2>/dev/null && sudo kill -9 "$pid" 2>/dev/null || true
done
sleep 0.5

echo "[cleanup] removing the cgroup directories that are left (the random parent of the first two, below every hierarchy), the bundles and the work dir..."
sudo find /sys/fs/cgroup -maxdepth 8 -depth -type d -name "$CASE_ID*" -exec rmdir {} \; 2>/dev/null
sudo rm -rf --one-file-system "$LIB_BASE"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-* "/tmp/$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
