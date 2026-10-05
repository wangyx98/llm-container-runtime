#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned), and every command here may fail without aborting the cleanup.

CASE_ID="bench77221042"
WORK_DIR="/tmp/$CASE_ID"

if command -v runc >/dev/null 2>&1; then
    echo "[cleanup] removing the runc container $CASE_ID (and any other runc container named after the case)..."
    for c in $(sudo runc list -q 2>/dev/null | grep -F "$CASE_ID"); do
        timeout -k 5 30 sudo runc delete --force "$c" >/dev/null 2>&1 || true
    done
fi

# mounts a solution may have made on the work dir (a bind mount, an overlay, a remounted rootfs)
# have to go before the files are removed
echo "[cleanup] unmounting anything mounted below the work dir..."
for m in $(awk -v d="$WORK_DIR/" 'index($2, d) == 1 {print $2}' /proc/mounts | sort -r); do
    sudo umount -l "$m" >/dev/null 2>&1 || true
done

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
