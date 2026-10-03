#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: /etc/crictl.yaml may point somewhere else from another case
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench71218538"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
POD_NAME="$CASE_ID-pod"
NAME_PREFIX="$CASE_ID"     # every container, pod and image name this case can create has this in it

if command -v crictl >/dev/null 2>&1 && [ -S "$SOCK" ] && $CRICTL info >/dev/null 2>&1; then
    echo "[cleanup] removing the containers and the pod sandbox of this case (by name, so"
    echo "[cleanup] a container a solution re-created is removed as well)..."
    # --timeout 1: the workload exits on SIGTERM at once, and a solution's
    # replacement container may not, so do not wait out the default 30 s
    for id in $($CRICTL ps -a -q --name "$NAME_PREFIX" 2>/dev/null); do
        $CRICTL stop --timeout 1 "$id" >/dev/null 2>&1 || true
        $CRICTL rm -f "$id" >/dev/null 2>&1 || true
    done
    for id in $($CRICTL pods -q --name "$POD_NAME" 2>/dev/null); do
        $CRICTL stopp "$id" >/dev/null 2>&1 || true
        $CRICTL rmp -f "$id" >/dev/null 2>&1 || true
    done
fi

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1; then
    echo "[cleanup] removing the images of this case from every containerd namespace. Only"
    echo "[cleanup] the names containing $NAME_PREFIX and the images' own sha256 records go;"
    echo "[cleanup] no other image is touched..."
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            sudo ctr -n "$ns" images rm --sync "$ref" >/dev/null 2>&1 || true
        done
        # an import into k8s.io also leaves a bare "sha256:<image id>" record
        for f in image_id_active image_id_stopped image_id_unused; do
            ID=$(cat "$STATE_DIR/$f" 2>/dev/null || true)
            [ -n "$ID" ] && sudo ctr -n "$ns" images rm --sync "sha256:$ID" >/dev/null 2>&1 || true
        done
    done
fi

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
