#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: /etc/crictl.yaml may still point at another runtime
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
WORK_DIR="/tmp/bench78814823"
NAME_PREFIX="bench78814823"          # every image this case can create
                                     # has this in its repository name

if command -v crictl >/dev/null 2>&1 && [ -S "$SOCK" ]; then
    echo "[cleanup] removing the image from the CRI's view (namespace k8s.io)..."
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
        $CRICTL rmi "$id" 2>/dev/null || true
    done
fi

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ]; then
    echo "[cleanup] removing the image from every containerd namespace..."
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            sudo ctr -n "$ns" images rm "$ref" >/dev/null 2>&1 || true
        done
    done
fi

echo "[cleanup] removing the work dir (report, hidden state)..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
