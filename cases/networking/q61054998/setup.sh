#!/bin/bash
set -e

CASE_ID="bench61054998"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_BASE="/var/lib/$CASE_ID"          # the bundle: root-owned, not in /tmp (which may be mounted noexec: the container runs a program from its rootfs)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record, the host service and the helpers
HPORT=35761                           # the host service on 127.0.0.1
CPORT=35762                           # the container's listener
CTL_PORT=35763                        # the listener of the control container

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking runc and python3 are installed (the runtime under test and the usual tools)..."
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }
runc --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking that the loopback ports $HPORT, $CPORT and $CTL_PORT are free, and that gcc is available (one tiny static program, so nothing has to be downloaded)..."
for p in $HPORT $CPORT $CTL_PORT; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "[setup] ERROR: something already listens on 127.0.0.1:$p"; exit 1; fi
done
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

echo "[setup] the engineer's bundle ($LIB_BASE/bundle: a config.json with a network namespace of its own), the service on the host's loopback ($HPORT), and the container $CASE_ID running from the bundle..."
python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. The container $CASE_ID runs in a network namespace of its own: its program cannot reach the host's 127.0.0.1:$HPORT and the host cannot reach the container's 127.0.0.1:$CPORT."
