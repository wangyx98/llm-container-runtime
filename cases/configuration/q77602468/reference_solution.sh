#!/bin/bash
set -e

W="/tmp/bench77602468"
IMG="private-gcr.invalid/bench77602468/app:1.0"
CONF="/var/lib/bench77602468/crio/crio.conf"

# where CRI-O keeps its images: the graph root, run root and driver of its configuration (a copy anywhere else is invisible to it)
conf() { awk -F'"' -v k="$1" '$1 ~ "^"k"[[:space:]]*=" {print $2; exit}' "$CONF"; }
ROOT=$(conf root); RUNROOT=$(conf runroot); DRIVER=$(conf storage_driver)
echo "[solution] CRI-O's storage: root $ROOT, run root $RUNROOT, driver $DRIVER"

echo "[solution] saving the image from Docker's store, and copying the archive into CRI-O's storage (same name)..."
T=$(mktemp -d)
"$W/bin/docker" save -o "$T/image.tar" "$IMG"
sudo skopeo copy "docker-archive:$T/image.tar" "containers-storage:[$DRIVER@$ROOT+$RUNROOT]$IMG"
rm -rf "$T"

echo "[solution] CRI-O sees it:"
"$W/bin/node-crictl" inspecti "$IMG" | grep -E '"id"|repoTags' | head -3
