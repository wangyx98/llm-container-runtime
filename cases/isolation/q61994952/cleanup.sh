#!/bin/bash
# no 'set -e': containers/files may legitimately not exist yet, and
# commands here are allowed to fail without aborting cleanup.

WORK_DIR="/tmp/bench61994952"
RUNC_ROOT="$WORK_DIR/runc-root"

C1="bench61994952-c1"
C2="bench61994952-c2"
C3="bench61994952-c3"
C4="bench61994952-c4"

echo "[cleanup] deleting any of the 4 runc containers that exist..."
for c in "$C1" "$C2" "$C3" "$C4"; do
    sudo runc --root "$RUNC_ROOT" delete -f "$c" 2>/dev/null || true
done

echo "[cleanup] removing work dir (bundles, rootfs, verdict, ground truth)..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
