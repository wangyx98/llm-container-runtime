#!/bin/bash
set -e

CASE_ID="bench71584810"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT_CTD="$CASE_ID-containerd.service"   # the node's containerd (the daemon whose log is wanted)
UNIT_REG="$CASE_ID-registry.service"     # a registry that does not let pulls through (HTTP 429, 403, 503)
UNIT_APP="$CASE_ID-app.service"          # an application that logs lines which look like the daemon's
RUN_BASE="/run/$CASE_ID"                 # socket and state of the containerd, the feed file of the application
LIB_BASE="/var/lib/$CASE_ID"             # its root, its configuration, the registry program (not in /run: noexec on many hosts)
T_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"             # the oracle's own record and the helpers

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking the machine runs systemd (PID 1) and has containerd, python3, journalctl and systemd-cat..."
[ -d /run/systemd/system ] && command -v systemctl >/dev/null \
    || { echo "[setup] ERROR: this machine is not booted with systemd"; exit 1; }
for b in containerd python3 journalctl systemd-cat tail; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

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
sudo mkdir -p "$RUN_BASE" "$LIB_BASE"
cp "$CASE_DIR"/helpers/{patch_config.py,lab.py,verify.py,registry.py} "$STATE_DIR/"
sudo cp "$STATE_DIR/registry.py" "$LIB_BASE/registry.py"
sha256sum "$STATE_DIR"/patch_config.py "$STATE_DIR"/lab.py "$STATE_DIR"/verify.py "$STATE_DIR"/registry.py | awk '{print $1}' > "$STATE_DIR/helpers.sha"

echo "[setup] a free port for the registry, and its host file for the containerd (plain HTTP on 127.0.0.1)..."
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
REG="127.0.0.1:$PORT"
sudo mkdir -p "$LIB_BASE/certs.d/$REG"
sudo tee "$LIB_BASE/certs.d/$REG/hosts.toml" >/dev/null <<TOML
server = "http://$REG"

[host."http://$REG"]
  capabilities = ["pull", "resolve"]
TOML

echo "[setup] the default containerd configuration of the installed version, for this node (own root, state and socket, NRI off)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE/containerd" "$T_SOCK" "$LIB_BASE/cni" "registry.invalid/pause:1" "$LIB_BASE/certs.d" \
    | sudo tee "$LIB_BASE/config.toml" >/dev/null
sudo grep -q "$LIB_BASE/certs.d" "$LIB_BASE/config.toml" || { echo "[setup] ERROR: could not set the registry host directory in the containerd config"; exit 1; }
sudo touch "$RUN_BASE/app.feed"

echo "[setup] writing the three systemd units (their output goes to the journal)..."
sudo tee "/etc/systemd/system/$UNIT_CTD" >/dev/null <<UNIT
[Unit]
Description=$CASE_ID containerd (the container runtime of the node)
After=network.target

[Service]
Type=simple
ExecStart=$(command -v containerd) --config $LIB_BASE/config.toml
Delegate=yes
KillMode=process
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
sudo tee "/etc/systemd/system/$UNIT_REG" >/dev/null <<UNIT
[Unit]
Description=$CASE_ID registry (does not let pulls through)

[Service]
Type=simple
ExecStart=$(command -v python3) -u $LIB_BASE/registry.py $PORT

[Install]
WantedBy=multi-user.target
UNIT
sudo tee "/etc/systemd/system/$UNIT_APP" >/dev/null <<UNIT
[Unit]
Description=$CASE_ID application (logs lines which look like the daemon's)

[Service]
Type=simple
SyslogIdentifier=containerd
ExecStart=$(command -v tail) -n 0 -F $RUN_BASE/app.feed

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl start "$UNIT_REG" "$UNIT_CTD" "$UNIT_APP"

CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
UP=""
for _ in $(seq 1 80); do
    if [ -S "$T_SOCK" ] && "${CRI[@]}" version >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: the node's containerd did not come up:"; sudo journalctl -u "$UNIT_CTD" -n 5 --no-pager -o cat | cut -c1-300; exit 1; }
for u in "$UNIT_REG" "$UNIT_CTD" "$UNIT_APP"; do
    [ "$(systemctl is-active "$u")" = active ] || { echo "[setup] ERROR: $u is not active"; exit 1; }
done

echo "[setup] the pulls: an image pulled before, the pull that matters, an image pulled after; the START and END cursors around the one"
echo "[setup] that matters are saved, and the registry and an application log the same words as the daemon..."
python3 "$STATE_DIR/lab.py" up "$T_SOCK" "$WORK_DIR" "$PORT" || { echo "[setup] ERROR: the pulls did not run"; exit 1; }
chmod 644 "$WORK_DIR/cursor.start" "$WORK_DIR/cursor.end"
echo "  -> the cursors are in $WORK_DIR/cursor.start and $WORK_DIR/cursor.end"

echo "[setup] done. $UNIT_CTD runs the node's containerd; its journal holds the pulls; there is no export-pull-log.sh."
