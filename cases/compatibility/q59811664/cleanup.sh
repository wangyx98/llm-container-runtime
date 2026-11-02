#!/bin/bash
# Idempotent; no 'set -e' (nothing here is guaranteed to exist). Removes everything the case or a
# sample can have made: CRI-O pod/container/images, host-podman containers and images, the build
# machine's store, the registry process, and any registry setting added for CRI-O (CRI-O is
# reloaded afterwards, so the next run starts with a CRI-O that knows nothing about the registry).
CASE_ID="bench59811664"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
WS_DIR="$WORK_DIR/workstation"
POD_NAME="$CASE_ID-pod"
CONTAINER_NAME="$CASE_ID"
NAME_PREFIX="$CASE_ID/"            # every image name of the case contains this
REGISTRY=$(sudo cat "$STATE_DIR/registry_addr" 2>/dev/null)
EXPECTED_ID=$(sudo cat "$STATE_DIR/expected_image_id" 2>/dev/null)

echo "[cleanup] removing the pod sandbox and the container from CRI-O..."
if command -v crictl >/dev/null 2>&1; then
    for c in $(sudo crictl ps -a --name "$CONTAINER_NAME" -q 2>/dev/null); do
        sudo crictl stop "$c" >/dev/null 2>&1
        sudo crictl rm -f "$c" >/dev/null 2>&1
    done
    for p in $(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null); do
        sudo crictl stopp "$p" >/dev/null 2>&1
        sudo crictl rmp -f "$p" >/dev/null 2>&1
    done
    echo "[cleanup] removing the case's images from CRI-O's store (by name, registry address and id)..."
    for id in $(sudo crictl images -o json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
prefix, reg, eid = sys.argv[1:4]
for img in data.get("images", []):
    refs = (img.get("repoTags") or []) + (img.get("repoDigests") or [])
    if prefix in " ".join(refs) or (reg and reg in " ".join(refs)) or (eid and img["id"].replace("sha256:", "") == eid):
        print(img["id"])
' "$NAME_PREFIX" "$REGISTRY" "$EXPECTED_ID"); do
        sudo crictl rmi "$id" >/dev/null 2>&1
    done
fi

if command -v podman >/dev/null 2>&1; then
    echo "[cleanup] removing host-podman containers/images of the case (root store = CRI-O's store; rootless store)..."
    for who in "sudo" ""; do
        for c in $($who podman ps -a --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null | awk -v p="$NAME_PREFIX" -v n="$CASE_ID" 'index($0, p) || index($2, n) == 1 {print $1}'); do
            $who podman rm -f "$c" >/dev/null 2>&1
        done
        for i in $($who podman images --format '{{.ID}} {{.Repository}}' 2>/dev/null | awk -v p="$NAME_PREFIX" 'index($2, p) {print $1}'); do
            $who podman rmi -f "$i" >/dev/null 2>&1
        done
    done
    if sudo test -d "$WS_DIR"; then
        echo "[cleanup] emptying the build machine's store..."
        sudo podman --root "$WS_DIR/root" --runroot "$WS_DIR/run" rm -af >/dev/null 2>&1
        sudo podman --root "$WS_DIR/root" --runroot "$WS_DIR/run" rmi -af >/dev/null 2>&1
    fi
fi

echo "[cleanup] stopping the registry process..."
for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    cmd=$(sudo tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$cmd" in
        "python3 $STATE_DIR/registry.py"*) sudo kill "$pid" >/dev/null 2>&1 ;;
    esac
done

echo "[cleanup] undoing registry settings for CRI-O and reloading it..."
CHANGED=0
for f in $(sudo grep -rlE "$CASE_ID|${REGISTRY:-@@none@@}" /etc/containers/registries.conf.d 2>/dev/null); do
    sudo rm -f "$f" && CHANGED=1
done
if sudo test -f "$STATE_DIR/containers-conf/registries.conf"; then
    if ! sudo cmp -s "$STATE_DIR/containers-conf/registries.conf" /etc/containers/registries.conf; then
        sudo cp -p "$STATE_DIR/containers-conf/registries.conf" /etc/containers/registries.conf && CHANGED=1
    fi
fi
if [ "$CHANGED" = 1 ] && pgrep -x crio >/dev/null 2>&1; then
    sudo kill -HUP "$(pgrep -x crio | head -1)" >/dev/null 2>&1
    sleep 1
fi

echo "[cleanup] removing the work dir (anything still mounted below it first, deepest first)..."
for m in $(awk -v w="$WORK_DIR" 'index($2, w) == 1 {print $2}' /proc/mounts | sort -r); do
    sudo umount -l "$m" >/dev/null 2>&1
done
sudo rm -rf "$WORK_DIR"
echo "[cleanup] done."
exit 0
