#!/bin/bash
# no 'set -e': teardown must tolerate things that were never created.

WORK_DIR="/tmp/bench58429514"
STATE_DIR="/var/lib/bench58429514"
CRIO_DROPIN_DIR="/etc/crio/crio.conf.d"
POD_NAME="bench58429514-pod"
CONTAINER_NAME="bench58429514-ctr"

echo "[cleanup] removing containers named '$CONTAINER_NAME'..."
for c in $(sudo crictl ps -a --name "$CONTAINER_NAME" -q 2>/dev/null); do
    sudo crictl stop -t 1 "$c" 2>/dev/null || true
    sudo crictl rm -f "$c" 2>/dev/null || true
done

echo "[cleanup] removing pod sandboxes named '$POD_NAME'..."
for p in $(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null); do
    sudo crictl stopp "$p" 2>/dev/null || true
    sudo crictl rmp -f "$p" 2>/dev/null || true
done

echo "[cleanup] removing CRI-O drop-ins created by this case or by a sample..."
sudo rm -f "$CRIO_DROPIN_DIR"/*bench58429514*
# Drop-ins that a solution created under another name: setup.sh recorded the
# drop-ins that existed BEFORE this case touched anything, so anything not on
# that list is ours to remove.
if [ -f "$STATE_DIR/dropins.orig" ] && [ -d "$CRIO_DROPIN_DIR" ]; then
    for f in "$CRIO_DROPIN_DIR"/*; do
        [ -e "$f" ] || continue
        if ! grep -qxF "$(basename "$f")" "$STATE_DIR/dropins.orig"; then
            echo "[cleanup]   removing drop-in added after setup: $f"
            sudo rm -f "$f"
        fi
    done
fi

echo "[cleanup] restarting crio so the baseline configuration is live again..."
if systemctl list-unit-files crio.service >/dev/null 2>&1; then
    sudo systemctl restart crio 2>/dev/null || true
    sleep 1
fi

echo "[cleanup] removing work dir and state..."
sudo rm -rf "$WORK_DIR" "$STATE_DIR"

echo "[cleanup] done. Environment reset to clean state."
