#!/bin/bash
set -e

CASE_ID="bench72094271"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$CASE_DIR/helpers"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): helpers, programs, images, truth.json
UNIT="$CASE_ID-containerd.service"
ETC="/etc/$CASE_ID"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
SOCK="$RUN/containerd.sock"
CORE_PATTERN="core.%e.%P"                        # a FILE pattern: a piped handler ignores RLIMIT_CORE

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking the tools: containerd, ctr, crictl, runc, systemctl, python3..."
for c in containerd ctr runc systemctl python3 sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
[ -d /run/systemd/system ] || echo "[setup] note: this host runs no systemd (a stand-in for systemctl is in use)"
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
CONTAINERD=$(command -v containerd)
containerd --version
crictl --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (two tiny static programs, so nothing has to be pulled)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir; the helpers go where only root can change them..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
cp "$HELPERS"/{probe.c,pause.c,mkimg.py,patch_config.py,lab.py,verify.py,baseline.py} "$STATE_DIR/"
( cd "$STATE_DIR" && sha256sum probe.c pause.c mkimg.py patch_config.py lab.py verify.py baseline.py | awk '{print $1}' > helpers.sha )
sudo install -d -m 755 "$ETC" "$LIB" "$RUN" "$LIB/cni/net.d" "$LIB/cni/bin"
sudo install -d -m 755 "$LIB/cores"

echo "[setup] the places where a core limit could be put besides the unit (PAM limits, systemd's defaults, sysctl, profiles) are recorded, to be put back by cleanup.sh..."
sudo python3 "$STATE_DIR/baseline.py" save "$LIB/baseline"

echo "[setup] kernel.core_pattern is fixed to the file pattern $CORE_PATTERN for the time of the case (the machine's value is kept in a root-only file and restored by cleanup.sh)..."
ORIG=$(cat /proc/sys/kernel/core_pattern)
sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$ORIG" "$LIB/core_pattern.orig"
sudo sh -c 'printf "%s\n" "$1" > /proc/sys/kernel/core_pattern' _ "$CORE_PATTERN" || { echo "[setup] ERROR: cannot set kernel.core_pattern"; exit 1; }
[ "$(cat /proc/sys/kernel/core_pattern)" = "$CORE_PATTERN" ] || { echo "[setup] ERROR: kernel.core_pattern did not take the lab's value"; exit 1; }

echo "[setup] compiling the programs of the images (the probe: serve, limits, abort; the sandbox program) and building them offline..."
gcc -static -Os -s -w -o "$STATE_DIR/probe-bin" "$STATE_DIR/probe.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"
python3 "$STATE_DIR/mkimg.py" "$CASE_ID.local/probe:1" "$STATE_DIR/probe-bin" probe "$STATE_DIR/probe.tar" >/dev/null
python3 "$STATE_DIR/mkimg.py" "$CASE_ID.local/pause:1" "$STATE_DIR/pause-bin" pause "$STATE_DIR/pause.tar" >/dev/null

echo "[setup] containerd's configuration of the node: the default one of the installed version, in its own root, state and socket (runc on cgroupfs, its runtime root below $RUN)..."
containerd config default | python3 "$STATE_DIR/patch_config.py" "$LIB/containerd" "$RUN/containerd" "$SOCK" "$LIB/cni" "$CASE_ID.local/pause:1" > "$STATE_DIR/containerd.toml"
grep -q "$CASE_ID.local/pause:1" "$STATE_DIR/containerd.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd configuration"; exit 1; }
sudo install -m 644 "$STATE_DIR/containerd.toml" "$ETC/containerd.toml"

echo "[setup] the service $UNIT: containerd with LimitCORE=infinity, as the unit of the upstream containerd.service has it..."
cat <<UNITF | sudo tee "/etc/systemd/system/$UNIT" >/dev/null
[Unit]
Description=containerd of the node $CASE_ID (a private instance; not containerd.service)
After=network.target

[Service]
Type=simple
ExecStart=$CONTAINERD --config $ETC/containerd.toml
Restart=on-failure
KillMode=process
Delegate=yes
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNITF
sudo systemctl daemon-reload
sudo systemctl start "$UNIT" || { echo "[setup] ERROR: $UNIT did not start"; sudo systemctl status "$UNIT" --no-pager 2>&1 | tail -8; sudo tail -8 "/var/log/$UNIT.log" 2>/dev/null; exit 1; }

echo "[setup] the images are imported (offline, namespace k8s.io) and the record of what is true is written..."
sudo chown -R root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. $UNIT (CRI socket $SOCK, configuration $ETC/containerd.toml) runs with LimitCORE=infinity: containers of the node have an unlimited core file size."
