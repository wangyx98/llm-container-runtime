#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: /etc/crictl.yaml may point somewhere else from another case
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench65393959"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NAME_PREFIX="$CASE_ID"     # every container, pod and image name this case can create has this in it

if command -v crictl >/dev/null 2>&1 && [ -S "$SOCK" ] && $CRICTL info >/dev/null 2>&1; then
    echo "[cleanup] removing the containers and pod sandboxes of this case (by name)..."
    # --timeout 1: the container's init does not react to SIGTERM (it only
    # pauses), so do not wait out the default 30 s
    for id in $($CRICTL ps -a -q --name "$NAME_PREFIX" 2>/dev/null); do
        $CRICTL stop --timeout 1 "$id" >/dev/null 2>&1 || true
        $CRICTL rm -f "$id" >/dev/null 2>&1 || true
    done
    for id in $($CRICTL pods -q --name "$NAME_PREFIX" 2>/dev/null); do
        $CRICTL stopp "$id" >/dev/null 2>&1 || true
        $CRICTL rmp -f "$id" >/dev/null 2>&1 || true
    done
fi

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1; then
    echo "[cleanup] removing containers made with ctr and the image of this case from every"
    echo "[cleanup] containerd namespace. Only names containing $NAME_PREFIX and the image's"
    echo "[cleanup] own sha256 record go; nothing else is touched..."
    ID=$(cat "$STATE_DIR/image_id" 2>/dev/null || true)
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for c in $(sudo ctr -n "$ns" containers ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            sudo ctr -n "$ns" tasks kill -s SIGKILL "$c" >/dev/null 2>&1 || true
            sudo ctr -n "$ns" tasks rm -f "$c" >/dev/null 2>&1 || true
            sudo ctr -n "$ns" containers rm "$c" >/dev/null 2>&1 || true
        done
        for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            sudo ctr -n "$ns" images rm --sync "$ref" >/dev/null 2>&1 || true
        done
        # an import into k8s.io also leaves a bare "sha256:<image id>" record
        if [ -n "$ID" ]; then
            sudo ctr -n "$ns" images rm --sync "sha256:$ID" >/dev/null 2>&1 || true
        fi
    done
fi

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
