#!/bin/bash
set -e

CASE_ID="bench56996594"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_BASE="/var/lib/$CASE_ID"          # root-owned, world-readable: digest.txt (the one fixed thing the task names by path)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record (root only)
USER_NAME="$CASE_ID"                  # the user who has to run containers without root
PORT=35996

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the tools of a rootless setup: rootlesskit, newuidmap/newgidmap (set-uid or with file capabilities), containerd, ctr, nsenter, systemctl, loginctl..."
need_rootless_pkgs=0
for c in rootlesskit newuidmap newgidmap; do command -v "$c" >/dev/null || need_rootless_pkgs=1; done
if [ "$need_rootless_pkgs" = 1 ]; then
    # rootlesskit and newuidmap/newgidmap are what the question's answer (rootless containers) is built on, not the thing under test: install them like gcc below
    echo "[setup] rootlesskit and/or uidmap (newuidmap, newgidmap) are not installed; installing the Ubuntu packages rootlesskit and uidmap..."
    sudo -E apt-get update -qq || true
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" rootlesskit uidmap || true
fi
for c in rootlesskit newuidmap newgidmap containerd ctr nsenter systemctl loginctl python3 sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found (a rootless setup needs rootlesskit and uidmap; containerd with ctr; install them: sudo apt-get install -y rootlesskit uidmap)"; exit 1; }
done
for c in newuidmap newgidmap; do
    p=$(command -v "$c")
    [ -u "$p" ] || getcap "$p" 2>/dev/null | grep -q cap_set || { echo "[setup] ERROR: $p is neither set-uid nor has file capabilities: a user cannot get a range of IDs"; exit 1; }
done
containerd --version | head -1
rootlesskit --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] the user $USER_NAME: no sudo, no group of a rootful daemon, a range of subordinate IDs, a systemd user manager that keeps running (lingering)..."
sudo useradd --create-home --shell /bin/bash --user-group "$USER_NAME"
grep -q "^$USER_NAME:" /etc/subuid || sudo usermod --add-subuids 700000-765535 "$USER_NAME"
grep -q "^$USER_NAME:" /etc/subgid || sudo usermod --add-subgids 700000-765535 "$USER_NAME"
USER_ID=$(id -u "$USER_NAME")
sudo loginctl enable-linger "$USER_NAME"
for _ in $(seq 1 60); do
    [ -d "/run/user/$USER_ID" ] && { [ ! -d /run/systemd/system ] || [ -S "/run/user/$USER_ID/bus" ] || [ -S "/run/user/$USER_ID/systemd/private" ]; } && break
    sleep 0.5
done
[ -d "/run/user/$USER_ID" ] || { echo "[setup] ERROR: no /run/user/$USER_ID: the user manager of $USER_NAME did not start"; exit 1; }

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo install -d -m 700 -o root -g root "$STATE_DIR"
sudo cp "$CASE_DIR"/helpers/{marker.c,mkoci.py,registry.py,lab.py,verify.py} "$STATE_DIR/"
sudo bash -c 'cd "$1" && sha256sum marker.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" > helpers.sha' _ "$STATE_DIR"
sudo gcc -static -O2 -o "$STATE_DIR/marker" "$STATE_DIR/marker.c"
install -d -m 1777 "$WORK_DIR/out"          # where the oracle's runs write their output files (the user bench56996594 has to be able to)
cd "$WORK_DIR"

echo "[setup] the two images (the pinned one and the one the tag latest points to) and the registry on 127.0.0.1:$PORT..."
sudo python3 "$STATE_DIR/mkoci.py" "$STATE_DIR/reg" "$STATE_DIR/marker" | sudo tee "$STATE_DIR/digests.json" >/dev/null
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the registry did not start"; exit 1; }
sudo install -d -m 755 "$LIB_BASE"
sudo python3 -c "import json,sys; print(json.load(open('$STATE_DIR/digests.json'))['pinned'])" | sudo tee "$LIB_BASE/digest.txt" >/dev/null
sudo chmod 644 "$LIB_BASE/digest.txt"

echo "[setup] done. User $USER_NAME (uid $USER_ID) and the registry exist; nothing else: no daemon, no service, no image of the user's."
