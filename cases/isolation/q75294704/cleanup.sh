#!/bin/bash
# no set -e: a teardown may fail on things that are not there

CASE_ID="bench75294704"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
NS="$CASE_ID"

echo "[cleanup] stopping and deleting every container, then the image, of the containerd namespace $NS..."
if command -v ctr >/dev/null 2>&1; then
    for c in $(sudo ctr -n "$NS" tasks ls -q 2>/dev/null); do
        sudo ctr -n "$NS" tasks kill -s SIGKILL "$c" >/dev/null 2>&1
    done
    sleep 1
    for c in $(sudo ctr -n "$NS" tasks ls -q 2>/dev/null); do
        sudo ctr -n "$NS" tasks delete -f "$c" >/dev/null 2>&1
    done
    for c in $(sudo ctr -n "$NS" containers ls -q 2>/dev/null); do
        sudo ctr -n "$NS" containers delete "$c" >/dev/null 2>&1
    done
    for i in $(sudo ctr -n "$NS" images ls -q 2>/dev/null); do
        sudo ctr -n "$NS" images rm "$i" >/dev/null 2>&1
    done
    sudo ctr namespaces rm "$NS" >/dev/null 2>&1
fi
sudo rm -rf /run/containerd/runc/"$NS" /run/containerd/io.containerd.runtime.v2.task/"$NS" 2>/dev/null

echo "[cleanup] removing the alias node, detaching the loop devices of the case (found by their backing files) and deleting the backing files..."
sudo rm -f /dev/$CASE_ID-vol
if command -v losetup >/dev/null 2>&1; then
    for img in "$LIB_BASE"/vol.img "$LIB_BASE"/decoy.img; do
        for dev in $(sudo losetup -j "$img" -O NAME -n 2>/dev/null); do
            sudo losetup -d "$dev" 2>/dev/null
        done
    done
fi

echo "[cleanup] removing the work dir and the lab's files..."
sudo rm -rf "$WORK_DIR" "$LIB_BASE"

echo "[cleanup] done. Environment reset to clean state."
