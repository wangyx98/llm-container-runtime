#!/bin/bash
set -e

CASE_ID="bench66642654"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$CASE_DIR/helpers"
LIB="/var/lib/$CASE_ID"
SNAP_DATA="$LIB/current"                         # the node's data directory (MicroK8s: /var/snap/microk8s/current)
SNAP_COMMON="$LIB/common"                        # containerd's root, state, socket and log (MicroK8s: /var/snap/microk8s/common)
ARGS="$SNAP_DATA/args"                           # the template and the generated containerd.toml
BIN="$LIB/bin"                                   # the launcher and mk8sctl (root-owned; not in /run: it is mounted noexec on many hosts)
SOCK="$SNAP_COMMON/run/containerd.sock"
RUN="/run/$CASE_ID"
REG_DIR="$RUN/registry"                          # the registry fixture: blobs, state.json (root-owned)
ADDR="10.66.64.45"                               # the registry's address: a /32 alias of lo (not 127.x: containerd pulls from loopback registries over plain HTTP by itself)
PORT=32000
ALIAS="lo:b66642"
PAUSE_REF="$CASE_ID.local/pause:1"               # the sandbox image of the pods, imported offline
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): helpers, programs, truth.json

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking the tools: containerd, ctr, runc, python3, curl, sudo..."
for c in containerd ctr runc python3 curl sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
containerd --version
crictl --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (two tiny static programs, so nothing has to be pulled from a public registry)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] checking that port $PORT is free (the registry add-on of MicroK8s uses it too)..."
python3 - "$PORT" <<'PYEOF' || { echo "[setup] ERROR: something already listens on port $PORT"; exit 1; }
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)     # sockets in TIME_WAIT of a previous run do not count; a listener does
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    sys.exit(1)
PYEOF

echo "[setup] resetting the work dir; the helpers go where only root can change them..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
FILES="lab.py verify.py mkimg.py patch_config.py registry.py alias.py app.c pause.c mk8sctl mk8s-run-containerd"
for f in $FILES; do cp "$HELPERS/$f" "$STATE_DIR/"; done
( cd "$STATE_DIR" && sha256sum $FILES | awk '{print $1}' > helpers.sha )
echo "$FILES" > "$STATE_DIR/helpers.list"

echo "[setup] compiling the two programs (myapp: prints a nonce and the salt of its image; the sandbox) and building the sandbox image offline..."
gcc -static -Os -s -w -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"
python3 "$STATE_DIR/mkimg.py" tar "$STATE_DIR/pause.tar" "$PAUSE_REF" "$STATE_DIR/pause-bin" pause >/dev/null

echo "[setup] the registry address $ADDR (an alias of lo, no 'ip' needed) and the registry on plain HTTP at $ADDR:$PORT..."
sudo chown -R root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo python3 "$STATE_DIR/alias.py" add "$ALIAS" "$ADDR" || { echo "[setup] ERROR: cannot add the address $ADDR to lo"; exit 1; }
sudo install -d -m 755 "$RUN" "$REG_DIR"
sudo env BENCH_BIND="$ADDR" setsid -f python3 "$STATE_DIR/registry.py" "$REG_DIR" "$PORT" "$RUN/registry.log" >/dev/null 2>&1 < /dev/null
for _ in $(seq 20); do curl -s --noproxy '*' --max-time 2 -o /dev/null "http://$ADDR:$PORT/v2/" && break; sleep 0.5; done
curl -s --noproxy '*' --max-time 2 -o /dev/null "http://$ADDR:$PORT/v2/" || { echo "[setup] ERROR: the registry does not answer at http://$ADDR:$PORT/v2/"; exit 1; }

echo "[setup] the node: the launcher (makes containerd.toml from the template at every start), mk8sctl, and the stock template from containerd's default configuration..."
sudo install -d -m 755 "$BIN" "$ARGS" "$SNAP_COMMON/run"
sudo install -m 755 "$STATE_DIR/mk8s-run-containerd" "$BIN/mk8s-run-containerd"
sudo install -m 755 "$STATE_DIR/mk8sctl" "$BIN/mk8sctl"
containerd config default | python3 "$HELPERS/patch_config.py" '${SNAP_COMMON}/var/lib/containerd' '${SNAP_COMMON}/run/containerd' '${SNAP_COMMON}/run/containerd.sock' '${SNAP_DATA}/cni' "$PAUSE_REF" > "$WORK_DIR/containerd-template.toml"
grep -q "$PAUSE_REF" "$WORK_DIR/containerd-template.toml" || { echo "[setup] ERROR: could not set the sandbox image in the configuration"; exit 1; }
grep -qF '${SNAP_COMMON}' "$WORK_DIR/containerd-template.toml" || { echo "[setup] ERROR: the template has no \${SNAP_COMMON}"; exit 1; }
sudo install -m 644 "$WORK_DIR/containerd-template.toml" "$ARGS/containerd-template.toml"
rm -f "$WORK_DIR/containerd-template.toml"

echo "[setup] starting the node with mk8sctl and importing the sandbox image (offline, namespace k8s.io)..."
sudo "$BIN/mk8sctl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$SNAP_COMMON/var/log/containerd.log" 2>/dev/null; exit 1; }
sudo ctr -a "$SOCK" -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }

echo "[setup] the record of what is true is written and the first build of myapp:latest is pushed to the registry..."
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. The node (CRI socket $SOCK, $ARGS/containerd.toml) cannot pull $ADDR:$PORT/myapp:latest: the registry speaks plain HTTP."
