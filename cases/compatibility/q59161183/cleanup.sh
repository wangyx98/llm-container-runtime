#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, tools not installed yet), and every command here may fail
# without aborting the cleanup.

POD_NAME="bench59161183-pod"
CONTAINER_NAME="bench59161183"
WORK_DIR="/tmp/bench59161183"
NAME_PREFIX="bench59161183/"          # every image this case can create
                                       # contains this in its repository name

echo "[cleanup] stopping + removing any container named '$CONTAINER_NAME'..."
if command -v crictl >/dev/null 2>&1; then
    for c in $(sudo crictl ps -a --name "$CONTAINER_NAME" -q 2>/dev/null); do
        sudo crictl stop "$c" 2>/dev/null || true
        sudo crictl rm -f "$c" 2>/dev/null || true
    done

    echo "[cleanup] stopping + removing any pod sandbox named '$POD_NAME'..."
    for p in $(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null); do
        sudo crictl stopp "$p" 2>/dev/null || true
        sudo crictl rmp -f "$p" 2>/dev/null || true
    done

    echo "[cleanup] removing the image from CRI-O's store, by name and by id..."
    EXPECTED_ID=$(cat "$WORK_DIR/.bench/expected_image_id" 2>/dev/null || true)
    for id in $(sudo crictl images -o json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for img in data.get("images", []):
    tags = img.get("repoTags") or []
    digests = img.get("repoDigests") or []
    if any("'"$NAME_PREFIX"'" in r for r in tags + digests):
        print(img["id"])
'); do
        sudo crictl rmi "$id" 2>/dev/null || true
    done
    if [ -n "$EXPECTED_ID" ]; then
        sudo crictl rmi "$EXPECTED_ID" 2>/dev/null || true
    fi
fi

# Other ways a sample may have put the image somewhere. The stores below are
# separate from CRI-O's; leftovers there would not break the next run, but
# the benchmark host is shared, so everything the case could have created
# is removed again.
if command -v podman >/dev/null 2>&1; then
    echo "[cleanup] removing the image from podman's root store (shared with CRI-O)..."
    for id in $(sudo podman images --format '{{.ID}} {{.Repository}}' 2>/dev/null \
                  | awk -v p="$NAME_PREFIX" 'index($2, p) {print $1}'); do
        sudo podman rmi -f "$id" >/dev/null 2>&1 || true
    done
    echo "[cleanup] removing the image from this user's rootless podman store..."
    for id in $(podman images --format '{{.ID}} {{.Repository}}' 2>/dev/null \
                  | awk -v p="$NAME_PREFIX" 'index($2, p) {print $1}'); do
        podman rmi -f "$id" >/dev/null 2>&1 || true
    done
    sudo podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

if command -v ctr >/dev/null 2>&1; then
    echo "[cleanup] removing the image from containerd's stores, if a sample imported it there..."
    for ns in default k8s.io moby; do
        for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$NAME_PREFIX"); do
            sudo ctr -n "$ns" images rm "$ref" >/dev/null 2>&1 || true
        done
    done
fi

echo "[cleanup] removing the work dir (tarball, JSON configs, hidden state)..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
