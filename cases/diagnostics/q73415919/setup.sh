#!/bin/bash
set -e

CASE_ID="bench73415919"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and log of the node's containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root and the RKE2 data directory (not in /run: it is mounted noexec on many hosts)
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
CFG_DIR="$LIB_BASE/rancher/rke2/agent/etc/containerd"    # where RKE2 writes config.toml and reads config.toml.tmpl
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
APP_REF="$CASE_ID.local/app:1"        # the image of the workload
PAUSE_REF="$CASE_ID.local/pause:1"    # the sandbox ("pause") image of the pods
DEFAULT_LIMIT=16384

CTR_T="sudo ctr -a $T_SOCK"

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
mkdir -p "$STATE_DIR" "$WORK_DIR/logs"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$T_STATE" "$T_ROOT" "$CFG_DIR"
cp "$CASE_DIR"/helpers/{patch_config.py,mkimg.py,emit.py,app.c,pause.c} "$STATE_DIR/"
cp "$CASE_DIR/helpers/restart-rke2.sh" "$WORK_DIR/restart-rke2.sh"
chmod 755 "$WORK_DIR/restart-rke2.sh"
cd "$WORK_DIR"

echo "[setup] compiling the programs of the images: the workload (it writes one long line with one write call) and the sandbox program..."
for p in app pause; do
    gcc -static -Os -s -w -o "$STATE_DIR/$p-bin" "$STATE_DIR/$p.c"
done

echo "[setup] the default containerd configuration of the installed version, for this node (own root, state and socket, NRI off, local sandbox image)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$T_ROOT" "$T_STATE" "$T_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    > "$STATE_DIR/containerd-base.toml"
grep -q "$PAUSE_REF" "$STATE_DIR/containerd-base.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
[ "$(grep -c "max_container_log_line_size = $DEFAULT_LIMIT\$" "$STATE_DIR/containerd-base.toml")" = 1 ] \
    || { echo "[setup] ERROR: this containerd's default configuration has no max_container_log_line_size = $DEFAULT_LIMIT"; exit 1; }
python3 - "$STATE_DIR/containerd-base.toml" <<'PYEOF'
import re
import sys

section = ""
for line in open(sys.argv[1]):
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    if line.strip().startswith("max_container_log_line_size"):
        print("  -> default limit: %s, in the table [%s]" % (line.split("=")[1].strip(), section.strip("'\"")))
PYEOF
sha256sum "$STATE_DIR"/patch_config.py "$STATE_DIR"/mkimg.py "$STATE_DIR"/emit.py "$STATE_DIR"/app.c "$STATE_DIR"/pause.c \
    "$STATE_DIR"/containerd-base.toml "$WORK_DIR"/restart-rke2.sh | awk '{print $1}' > "$STATE_DIR/helpers.sha"

echo "[setup] starting the node's containerd the way RKE2 does (config.toml rendered, no template yet; the restart script of the node)..."
bash "$WORK_DIR/restart-rke2.sh" || { echo "[setup] ERROR: the node's containerd did not come up"; exit 1; }
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)

echo "[setup] importing the two images into the 'k8s.io' namespace (the sandbox image and the image of the workload)..."
for pair in "pause:$PAUSE_REF" "app:$APP_REF"; do
    k=${pair%%:*}; ref=${pair#*:}
    python3 "$STATE_DIR/mkimg.py" "$ref" "$STATE_DIR/$k-bin" "$STATE_DIR/$k.tar" >/dev/null
    chmod 0644 "$STATE_DIR/$k.tar"
    $CTR_T -n k8s.io images import "$STATE_DIR/$k.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $ref"; exit 1; }
    rm -f "$STATE_DIR/$k.tar"
done
for ref in "$PAUSE_REF" "$APP_REF"; do
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "$ref" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know $ref"; exit 1; }
done

echo "[setup] removing the build inputs the solution has no business with (the programs, the image generator)..."
rm -f "$STATE_DIR/app-bin" "$STATE_DIR/pause-bin"

echo "[setup] done. The RKE2 node's containerd ($T_SOCK) runs with the default configuration; the workload image is $APP_REF."
