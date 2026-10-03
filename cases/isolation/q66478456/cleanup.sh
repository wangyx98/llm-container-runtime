#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench66478456"
WORK_DIR="/tmp/$CASE_ID"
NAME_PREFIX="$CASE_ID"     # every container and image name this case can create has this in it

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1; then
    echo "[cleanup] removing containers of this case and its image from every containerd"
    echo "[cleanup] namespace. Only names containing $NAME_PREFIX go; nothing else is touched..."
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for c in $(sudo ctr -n "$ns" containers ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            # the task may be running, stopped or gone; its init only pauses
            timeout -k 5 20 sudo ctr -n "$ns" tasks kill -s SIGKILL "$c" >/dev/null 2>&1 || true
            timeout -k 5 20 sudo ctr -n "$ns" tasks delete --force "$c" >/dev/null 2>&1 || true
            timeout -k 5 20 sudo ctr -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
        done
        # --sync also drops the remapped snapshot a --uidmap/--gidmap run leaves behind
        for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            timeout -k 5 60 sudo ctr -n "$ns" images rm --sync "$ref" >/dev/null 2>&1 || true
        done
    done
fi

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
