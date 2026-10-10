#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned), and every command here may fail without aborting the cleanup.

CASE_ID="bench75716847"
WORK_DIR="/tmp/$CASE_ID"
BUNDLE="$WORK_DIR/bundle"

echo "[cleanup] removing the containers of this case from runc (default root /run/runc)..."
for id in "$CASE_ID" "$CASE_ID-control"; do
    sudo timeout -k 3 20 runc kill "$id" KILL >/dev/null 2>&1 || true
    sudo timeout -k 3 20 runc delete -f "$id" >/dev/null 2>&1 || true
done
# containers a solution may have started under another id or runc root: every process whose root is this rootfs
for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    case "$(sudo readlink "$p/root" 2>/dev/null)" in
        "$BUNDLE/rootfs"*) sudo kill -KILL "$pid" 2>/dev/null || true ;;
    esac
done
sleep 0.5

# Unmount whatever is still mounted below the work dir (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount.
for _ in 1 2 3; do
    for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$WORK_DIR(/|$)" | sort -r); do
        sudo umount -l "$m" 2>/dev/null || true
    done
done
# the cgroup directories of the containers (runc removes them on delete; a killed runc may not)
sudo find /sys/fs/cgroup -depth -type d -name "$CASE_ID*" -exec rmdir {} \; 2>/dev/null || true
sudo rm -rf --one-file-system "/run/runc/$CASE_ID" "/run/runc/$CASE_ID-control" 2>/dev/null || true

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf --one-file-system "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
