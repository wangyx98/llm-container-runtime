#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench74595501"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NAME_PREFIX="$CASE_ID"     # every image name and container id this case can create has this in it
CTR="sudo ctr"

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && $CTR version >/dev/null 2>&1; then
    IMAGE_ID=$(cat "$STATE_DIR/image_id" 2>/dev/null || true)
    echo "[cleanup] removing containers and image names of this case from every containerd"
    echo "[cleanup] namespace (default, k8s.io, and any a solution made up). Only the names"
    echo "[cleanup] and the image's own records go: another image that a solution tagged with"
    echo "[cleanup] this case's name keeps its own names and content..."
    for ns in $($CTR namespaces ls -q 2>/dev/null); do
        for c in $($CTR -n "$ns" containers ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            $CTR -n "$ns" tasks kill -s SIGKILL "$c" >/dev/null 2>&1 || true
            $CTR -n "$ns" tasks rm -f "$c" >/dev/null 2>&1 || true
            $CTR -n "$ns" containers rm "$c" >/dev/null 2>&1 || true
        done
        for ref in $($CTR -n "$ns" images ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            $CTR -n "$ns" images rm --sync "$ref" >/dev/null 2>&1 || true
        done
        # an import into k8s.io also leaves a bare "sha256:<image id>" record
        if [ -n "$IMAGE_ID" ]; then
            $CTR -n "$ns" images rm --sync "sha256:$IMAGE_ID" >/dev/null 2>&1 || true
        fi
    done
fi

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
