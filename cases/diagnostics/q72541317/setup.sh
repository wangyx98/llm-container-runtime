#!/bin/bash
set -e

CASE_ID="bench72541317"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and log of the containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root: the content store is $T_ROOT/io.containerd.content.v1.content
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
UNUSED_PAUSE="$CASE_ID.local/pause:1" # the sandbox image of the CRI plugin's configuration (no pod is ever run here)

CTR="sudo ctr -a $T_SOCK"

echo "[setup] checking containerd, ctr and python3 are installed (the runtime under test and the usual tools)..."
for b in containerd ctr python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$T_STATE" "$T_ROOT"
cp "$CASE_DIR"/helpers/{patch_config.py,mkoci.py,lab.py,verify.py} "$STATE_DIR/"
cd "$WORK_DIR"

echo "[setup] the default containerd configuration of the installed version, for this containerd (own root, state and socket, NRI off)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$T_ROOT" "$T_STATE" "$T_SOCK" "$LIB_BASE/cni" "$UNUSED_PAUSE" \
    > "$STATE_DIR/containerd.toml"
(cd "$STATE_DIR" && sha256sum patch_config.py mkoci.py lab.py verify.py | awk '{print $1}' > helpers.sha)

echo "[setup] starting containerd (own socket $T_SOCK, own root and state)..."
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$STATE_DIR/containerd.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
UP=""
for _ in $(seq 1 80); do
    if [ -S "$T_SOCK" ] && $CTR version >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: containerd did not come up:"; sudo tail -5 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] building the images offline and importing them into the content store (no registry, no pull)..."
python3 "$STATE_DIR/lab.py" up "$T_SOCK" "$WORK_DIR" || { echo "[setup] ERROR: the images could not be built and imported"; exit 1; }
rm -f "$STATE_DIR"/*.tar

echo "[setup] done. containerd ($T_SOCK) holds the images; nothing says how to see the manifest of one."
