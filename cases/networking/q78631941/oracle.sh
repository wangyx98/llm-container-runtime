#!/bin/bash
set -e

CASE_ID="bench78631941"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the helpers are as setup copied them; containerd and its configuration, the registry and its images, the binary of the SOCI snapshotter, the network are as setup made them..."
(cd "$STATE_DIR" && sha256sum reader.c mkimage.py registry.py lab.py verify.py patch_config.py soci-service | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
python3 "$STATE_DIR/lab.py" check "$WORK_DIR" 2>&1 || fail "the lab is not as setup left it (see the line above)"
echo "  -> OK"

echo "[oracle] the program in $WORK_DIR/app builds and makes a NEW container from a NEW image through the snapshotter soci: the layer is mounted through FUSE by the snapshotter, a file deep in it reads with the right sha256, the snapshotter fetched from the registry over plain HTTP, the layer was not downloaded whole..."
python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1 || fail "see above"
