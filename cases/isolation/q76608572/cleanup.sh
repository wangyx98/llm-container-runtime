#!/bin/bash
# no set -e: a teardown may fail on things that are not there

CASE_ID="bench76608572"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

echo "[cleanup] deleting the containers of the case (found by their IDs in runc's default root)..."
if command -v runc >/dev/null 2>&1; then
    for id in $(sudo runc list -q 2>/dev/null | grep "^$CASE_ID-"); do
        sudo runc delete -f "$id" >/dev/null 2>&1
    done
fi
sudo rm -rf /run/runc/"$CASE_ID"-* 2>/dev/null

echo "[cleanup] removing the cgroups of the case (all levels, deepest first; a few tries: the kernel needs a moment to reap)..."
for _ in 1 2 3 4 5 6; do
    left=0
    for top in $(sudo find /sys/fs/cgroup -maxdepth 1 -type d -name "$CASE_ID*" 2>/dev/null); do
        sudo find "$top" -depth -type d -exec rmdir {} \; 2>/dev/null
        [ -d "$top" ] && left=1
    done
    [ $left = 0 ] && break
    sleep 1
done

echo "[cleanup] removing the work dir and the lab's files..."
sudo rm -rf "$WORK_DIR" "$LIB_BASE"

echo "[cleanup] done. Environment reset to clean state."
