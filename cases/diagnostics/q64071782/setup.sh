#!/bin/bash
set -e

CASE_ID="bench64071782"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_BASE="/var/lib/$CASE_ID"          # the bundles: root-owned, and not in /tmp or /run (which may be mounted noexec: the container runs a program from its rootfs)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record, the control files of the containers and the helpers

echo "[setup] checking runc, gcc and python3 are installed (the runtime under test, one tiny static program, the usual tools)..."
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }
runc --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (nothing has to be downloaded for the workload)..."
if ! command -v gcc >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold gcc libc6-dev
fi

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
cp "$CASE_DIR"/helpers/{app.c,lab.py,verify.py} "$STATE_DIR/"
sha256sum "$STATE_DIR"/app.c "$STATE_DIR"/lab.py "$STATE_DIR"/verify.py | awk '{print $1}' > "$STATE_DIR/helpers.sha"
gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
cd "$WORK_DIR"

echo "[setup] starting two runc containers (bundles below $LIB_BASE): the first process sleeps, its child uses CPU time when the lab tells it to..."
python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the containers were not started"; exit 1; }

echo "[setup] done. bench64071782-job and bench64071782-app run; there is no cpu-usage.sh."
