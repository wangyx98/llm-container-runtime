#!/bin/bash
set -e

CONTAINER="bench74317699"
WORK_DIR="/tmp/bench74317699"
BUNDLE_DIR="$WORK_DIR/bundle"
ROOTFS="$BUNDLE_DIR/rootfs"

echo "[setup] ensuring busybox-static is installed..."
if ! command -v busybox >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq busybox-static
fi
BUSYBOX_BIN="$(command -v busybox)"

echo "[setup] building minimal OCI bundle rootfs at $ROOTFS ..."
sudo rm -rf "$WORK_DIR"
sudo mkdir -p "$ROOTFS/bin" "$ROOTFS/proc" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/etc"
sudo cp "$BUSYBOX_BIN" "$ROOTFS/bin/busybox"

echo "[setup] generating config.json via 'runc spec'..."
sudo runc spec --bundle "$BUNDLE_DIR"

echo "[setup] patching config.json (process = busybox sleep, detached/no tty)..."
sudo python3 - "$BUNDLE_DIR/config.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
cfg["process"]["terminal"] = False
cfg["process"]["args"] = ["/bin/busybox", "sleep", "100000"]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF

echo "[setup] removing any leftover container with the same id (idempotency)..."
sudo runc delete -f "$CONTAINER" 2>/dev/null || true

echo "[setup] starting container detached (runc run --detach)..."
sudo runc run --bundle "$BUNDLE_DIR" --detach "$CONTAINER" < /dev/null > /dev/null 2>&1

sleep 1
echo "[setup] confirming container is RUNNING..."
STATUS=$(sudo runc list --format json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data:
    if c.get('id') == '$CONTAINER':
        print(c.get('status', ''))
        break
")
if [ "$STATUS" != "running" ]; then
    echo "  -> FAIL: expected 'running' right after start, got '${STATUS:-<not found>}'"
    exit 1
fi
echo "  -> OK"

echo "[setup] killing the container (mirrors the SO scenario: 'runc kill')..."
sudo runc kill "$CONTAINER" KILL

sleep 1
echo "[setup] confirming container transitioned to STOPPED..."
STATUS=$(sudo runc list --format json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data:
    if c.get('id') == '$CONTAINER':
        print(c.get('status', ''))
        break
")
if [ "$STATUS" != "stopped" ]; then
    echo "  -> FAIL: expected 'stopped' after kill, got '${STATUS:-<not found>}'"
    exit 1
fi
echo "  -> OK"

echo "[setup] done. Container '$CONTAINER' is now stopped, bundle intact at $BUNDLE_DIR."
