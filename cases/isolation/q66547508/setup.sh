#!/bin/bash
set -e

CASE_ID="bench66547508"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_BASE="/var/lib/$CASE_ID"          # the bundle: root-owned, not in /tmp (which may be mounted noexec: the container runs a program from its rootfs)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record, the nonce service and the helpers

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking runc and python3 are installed (the runtime under test and the usual tools)..."
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }
runc --version | head -1

echo "[setup] checking the kernel lets root create user namespaces (what the mapping needs)..."
if ! unshare -U true 2>/dev/null && ! sudo unshare -U true 2>/dev/null; then
    echo "[setup] ERROR: this kernel does not allow user namespaces (user.max_user_namespaces=0?)"
    exit 1
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
cp "$CASE_DIR"/helpers/{app.c,nonce_server.py,lab.py,verify.py} "$STATE_DIR/"
sha256sum "$STATE_DIR"/app.c "$STATE_DIR"/nonce_server.py "$STATE_DIR"/lab.py "$STATE_DIR"/verify.py | awk '{print $1}' > "$STATE_DIR/helpers.sha"
gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
cd "$WORK_DIR"

echo "[setup] the engineer's bundle ($LIB_BASE/bundle: a rootfs owned by host id 5000, a config.json with a user namespace and no network namespace) and the nonce service on the host's loopback..."
python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the bundle was not made"; exit 1; }

echo "[setup] done. Nothing runs yet: the engineer's 'runc run' on this bundle fails; there is no container $CASE_ID."
