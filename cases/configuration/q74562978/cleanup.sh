#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: /etc/crictl.yaml may point somewhere else from another case
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench74562978"
RUN_DIR="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
NAME_PREFIX="$CASE_ID"     # every image this case can create has this in its name

echo "[cleanup] stopping the registry..."
# Match by process name first and by command line second: 'pkill -f <path>'
# would also kill any shell whose own command line merely contains the path,
# including the one running this script.
for pid in $(pgrep -x python3 2>/dev/null); do
    if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "registry_server.py --dir $WORK_DIR/registry"; then
        sudo kill -9 "$pid" 2>/dev/null || true
    fi
done

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

echo "[cleanup] removing the registry config the case may have left, the /etc/hosts"
echo "[cleanup] entry, and putting containerd's config back to its default..."
sudo rm -rf "/etc/containerd/certs.d/registry.bench74562978.test:25562" /etc/containerd/certs.d/_default
sudo rmdir /etc/containerd/certs.d 2>/dev/null || true
sudo sed -i "/# bench74562978\$/d" /etc/hosts
if command -v containerd >/dev/null 2>&1; then
    DEFAULT_CFG=$(mktemp)
    containerd config default > "$DEFAULT_CFG" 2>/dev/null
    # restart only when the config really differs (systemd's start rate limit)
    if [ -s "$DEFAULT_CFG" ] && ! sudo cmp -s "$DEFAULT_CFG" /etc/containerd/config.toml; then
        sudo mkdir -p /etc/containerd
        sudo install -m 0644 "$DEFAULT_CFG" /etc/containerd/config.toml
        sudo systemctl reset-failed containerd 2>/dev/null || true
        sudo systemctl restart containerd 2>/dev/null || true
        for _ in $(seq 1 20); do
            [ -S "$SOCK" ] && break
            sleep 0.5
        done
    fi
    rm -f "$DEFAULT_CFG"
fi

echo "[cleanup] removing the work dir and the run dir..."
sudo rm -rf "$WORK_DIR" "$RUN_DIR"

echo "[cleanup] done. Environment reset to clean state."
