#!/bin/bash
set -e

CASE_ID="bench75294704"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_BASE="/var/lib/$CASE_ID"          # the backing files of the disks and the image archive (root-only)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the helpers of the lab, the program, and the lab's record
NS="$CASE_ID"                         # the containerd namespace of the case

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking containerd (system socket), ctr, losetup, mkfs.ext4, tune2fs and python3..."
for b in ctr losetup mkfs.ext4 tune2fs python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
sudo ctr version >/dev/null 2>&1 || { echo "[setup] ERROR: containerd does not answer on its system socket"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir, copying the helpers, building the program..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
cp "$CASE_DIR"/helpers/{scan.c,mkimg.py,lab.py,verify.py} "$STATE_DIR/"
(cd "$STATE_DIR" && sha256sum scan.c mkimg.py lab.py verify.py | awk '{print $1}' > helpers.sha)
gcc -static -O2 -o "$STATE_DIR/scan" "$STATE_DIR/scan.c"

echo "[setup] the volume (an ext4 disk on a loop device) and a decoy disk, the administrator's alias node for the volume, and the image in the namespace $NS..."
sudo mkdir -p "$LIB_BASE"
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR"

echo "[setup] done. Disks:"
sudo losetup -a | grep "$LIB_BASE" | cut -c1-120
ls -l /dev/$CASE_ID-vol
