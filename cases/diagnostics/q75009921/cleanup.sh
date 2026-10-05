#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75009921"
WORK_DIR="/tmp/$CASE_ID"
IMAGE_REF="docker.io/library/$CASE_ID:latest"

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1; then
    echo "[cleanup] removing the containers made from this case's image or named after it, in every"
    echo "[cleanup] namespace, then the image, then the namespaces named after the case. Nothing else"
    echo "[cleanup] is touched..."
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for c in $(sudo ctr -n "$ns" containers ls -q 2>/dev/null); do
            IMAGE_OF=$(sudo ctr -n "$ns" containers info "$c" 2>/dev/null \
                | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Image",""))' 2>/dev/null || true)
            if [ "$IMAGE_OF" = "$IMAGE_REF" ] || [ "${c#*$CASE_ID}" != "$c" ]; then
                timeout -k 5 20 sudo ctr -n "$ns" tasks kill -s SIGKILL "$c" >/dev/null 2>&1 || true
                timeout -k 5 20 sudo ctr -n "$ns" tasks delete --force "$c" >/dev/null 2>&1 || true
                timeout -k 5 20 sudo ctr -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
            fi
        done
        for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$CASE_ID"); do
            timeout -k 5 60 sudo ctr -n "$ns" images rm --sync "$ref" >/dev/null 2>&1 || true
        done
    done
    # a namespace can only be removed once containerd's garbage collector has dropped the image's
    # blobs, which may take a moment after the image is gone: retry for a few seconds
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null | grep -F "$CASE_ID"); do
        for _ in $(seq 1 10); do
            sudo ctr namespaces rm "$ns" >/dev/null 2>&1 && break
            sleep 1
        done
    done
fi

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
