#!/bin/bash
set -e

CASE_ID="bench61055917"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and log of the node's containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root (not in /run: it is mounted noexec on many hosts)
T_SOCK="$RUN_BASE/containerd/containerd.sock"        # the containerd of the node (the MicroK8s one)
O_SOCK="$RUN_BASE/docker/containerd.sock"            # the socket of ANOTHER containerd of the host: nothing may connect to it
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
PAUSE_REF="k8s.gcr.io/pause:3.1"      # the sandbox ("pause") image setting of the config (no pod runs on this node)

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking containerd, ctr, runc and python3 are installed (the runtime under test and the usual tools)..."
for b in containerd ctr runc python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$T_STATE" "$T_ROOT" "$RUN_BASE/docker"
cp "$CASE_DIR"/helpers/{patch_config.py,mkimg.py,lab.py,verify.py,idle.c,tap.py} "$STATE_DIR/"
cd "$WORK_DIR"

echo "[setup] compiling the program of the images (it does nothing and never exits)..."
gcc -static -Os -s -w -o "$STATE_DIR/idle-bin" "$STATE_DIR/idle.c"

echo "[setup] the default containerd configuration of the installed version, for this node (own root, state and socket, NRI off)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$T_ROOT" "$T_STATE" "$T_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    > "$STATE_DIR/containerd.toml"
grep -q "$PAUSE_REF" "$STATE_DIR/containerd.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
sha256sum "$STATE_DIR"/patch_config.py "$STATE_DIR"/mkimg.py "$STATE_DIR"/lab.py "$STATE_DIR"/verify.py "$STATE_DIR"/idle.c "$STATE_DIR"/tap.py \
    | awk '{print $1}' > "$STATE_DIR/helpers.sha"

echo "[setup] starting the node's containerd (own socket $T_SOCK, own root and state)..."
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$STATE_DIR/containerd.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
UP=""
for _ in $(seq 1 80); do
    if [ -S "$T_SOCK" ] && sudo ctr -a "$T_SOCK" version >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: the node's containerd did not come up:"; sudo tail -5 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] the socket of the other containerd of the host (a listener that only logs who connects; it is not part of the node)..."
sudo setsid -f python3 "$STATE_DIR/tap.py" "$O_SOCK" "$STATE_DIR/tap.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 40); do [ -S "$O_SOCK" ] && break; sleep 0.25; done
[ -S "$O_SOCK" ] || { echo "[setup] ERROR: the second socket did not come up"; exit 1; }

echo "[setup] importing the images into the namespace k8s.io and creating the containers (some with a running task, one never started)..."
python3 "$STATE_DIR/lab.py" up "$T_SOCK" "$WORK_DIR" || { echo "[setup] ERROR: the containers were not created"; sudo tail -5 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] done. The node's containerd ($T_SOCK) holds its images and containers in the namespace k8s.io (default is empty); another containerd socket is at $O_SOCK; there is no list-node.sh."
