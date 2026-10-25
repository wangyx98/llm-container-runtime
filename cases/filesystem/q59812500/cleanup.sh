#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned), and every command here may fail without aborting the cleanup.

CASE_ID="bench59812500"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# Processes still chrooted in the rootfs or running from it, and any daemon of the case. No 'pkill -f <text>': it would also kill the shell that runs this script.
echo "[cleanup] stopping what runs in the rootfs..."
for sig in TERM KILL; do
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        [ "$pid" = "$$" ] && continue
        r=$(sudo readlink "$d/root" 2>/dev/null); e=$(sudo readlink "$d/exe" 2>/dev/null)
        case "$r $e" in
            "$LIB/rootfs"*|*" $LIB/daemon/"*|*" $WORK_DIR/"*) sudo kill "-$sig" "$pid" 2>/dev/null ;;
        esac
    done
    sleep 0.5
done

echo "[cleanup] removing the lab and the work dir (the Go release stays in /var/cache/$CASE_ID)..."
sudo rm -rf --one-file-system "$LIB" "$WORK_DIR" "$WORK_DIR"-*
echo "[cleanup] done. Environment reset to clean state."
