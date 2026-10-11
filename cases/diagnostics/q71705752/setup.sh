#!/bin/bash
set -e

CASE_ID="bench71705752"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and log of the node's containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root (not in /run: it is mounted noexec on many hosts)
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
PAUSE_REF="$CASE_ID.local/pause:1"    # the sandbox ("pause") image of the pods

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking containerd, ctr, runc and python3 are installed (the runtime under test and the usual tools)..."
for b in containerd ctr runc python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (tiny static programs, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] ensuring crictl is installed (the CRI client; same pinned version as the other containerd cases)..."
if ! command -v crictl >/dev/null 2>&1; then
    echo "[setup] crictl not found, downloading $CRICTL_VERSION..."
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
crictl --version

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$T_STATE" "$T_ROOT"
cp "$CASE_DIR"/helpers/{patch_config.py,mkimg.py,lab.py,verify.py,app.c,pause.c} "$STATE_DIR/"
cd "$WORK_DIR"

echo "[setup] compiling the programs of the images: the workload (a token keeper that is also its own cat and id) and the sandbox program..."
for p in app pause; do
    gcc -static -Os -s -w -o "$STATE_DIR/$p-bin" "$STATE_DIR/$p.c"
done

echo "[setup] the default containerd configuration of the installed version, for this node (own root, state and socket, NRI off, local sandbox image)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$T_ROOT" "$T_STATE" "$T_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    > "$STATE_DIR/containerd.toml"
grep -q "$PAUSE_REF" "$STATE_DIR/containerd.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
sha256sum "$STATE_DIR"/patch_config.py "$STATE_DIR"/mkimg.py "$STATE_DIR"/lab.py "$STATE_DIR"/verify.py "$STATE_DIR"/app.c "$STATE_DIR"/pause.c \
    | awk '{print $1}' > "$STATE_DIR/helpers.sha"

echo "[setup] starting the node's containerd (own socket $T_SOCK, own root and state)..."
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$STATE_DIR/containerd.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
UP=""
for _ in $(seq 1 80); do
    if [ -S "$T_SOCK" ] && "${CRI[@]}" version >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: the node's containerd did not come up:"; sudo tail -5 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] importing the images into the 'k8s.io' namespace and running three pods through the CRI (two of them with a container of the same name)..."
python3 "$STATE_DIR/lab.py" up "$T_SOCK" "$WORK_DIR" || { echo "[setup] ERROR: the workloads did not come up"; exit 1; }

echo "[setup] done. The node's containerd ($T_SOCK) runs pods prod/rabbitmq-0 and staging/rabbitmq-0 (a container rabbitmq each) and has run prod/job-0; there is no inspect-node.sh."
