#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: /etc/crictl.yaml may point somewhere else from another case
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench74849789"
WORK_DIR="/tmp/$CASE_ID"
POD_NAME="$CASE_ID-pod"
NAME_PREFIX="$CASE_ID"     # every image this case can create has this in its name

if command -v crictl >/dev/null 2>&1 && [ -S "$SOCK" ] && $CRICTL info >/dev/null 2>&1; then
    echo "[cleanup] removing the workload container(s) and the pod sandbox (by name, so"
    echo "[cleanup] a container a solution re-created is removed as well)..."
    # --timeout 1: the workload exits on SIGTERM at once, and a solution's
    # replacement container may not, so do not wait out the default 30 s
    for id in $($CRICTL ps -a -q --name "$CASE_ID" 2>/dev/null); do
        $CRICTL stop --timeout 1 "$id" >/dev/null 2>&1 || true
        $CRICTL rm -f "$id" >/dev/null 2>&1 || true
    done
    for id in $($CRICTL pods -q --name "$POD_NAME" 2>/dev/null); do
        $CRICTL stopp "$id" >/dev/null 2>&1 || true
        $CRICTL rmp -f "$id" >/dev/null 2>&1 || true
    done

    echo "[cleanup] removing the workload image from the CRI's view (namespace k8s.io)..."
    for id in $($CRICTL images -o json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for img in data.get("images", []):
    names = (img.get("repoTags") or []) + (img.get("repoDigests") or [])
    if any("'"$NAME_PREFIX"'" in n for n in names):
        print(img["id"])
'); do
        $CRICTL rmi "$id" >/dev/null 2>&1 || true
    done
fi

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ]; then
    echo "[cleanup] removing the workload image from every containerd namespace..."
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            sudo ctr -n "$ns" images rm "$ref" >/dev/null 2>&1 || true
        done
    done
fi

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
