#!/bin/bash
set -e

CASE_ID="bench59744000"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and log of the node's containerd
LIB_BASE="/var/lib/$CASE_ID"          # the node: containerd's root, the configuration files, the kubelet's manifests and log (not in /run: it is mounted noexec on many hosts)
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
ETC="$LIB_BASE/etc"
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

echo "[setup] checking containerd, ctr, runc and python3 are installed, and that the host runs systemd (the systemd cgroup driver needs it)..."
for b in containerd ctr runc python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
[ -d /run/systemd/system ] || { echo "[setup] ERROR: this host does not run systemd (no /run/systemd/system): the case needs the systemd cgroup driver"; exit 1; }
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
sudo mkdir -p "$RUN_BASE" "$T_STATE" "$T_ROOT" "$ETC/manifests" "$LIB_BASE/bin"
cp "$CASE_DIR"/helpers/{patch_config.py,mkimg.py,lab.py,verify.py,kubelet-sim,app.c,pause.c} "$STATE_DIR/"
cd "$WORK_DIR"

echo "[setup] compiling the programs of the images: the workload (a token keeper that is also its own cat) and the sandbox program..."
for p in app pause; do
    gcc -static -Os -s -w -o "$STATE_DIR/$p-bin" "$STATE_DIR/$p.c"
done

echo "[setup] containerd's configuration for this node: the default one of the installed version, in its own root, state and socket, with runc on the systemd cgroup driver..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$T_ROOT" "$T_STATE" "$T_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    > "$STATE_DIR/containerd.toml"
grep -q "$PAUSE_REF" "$STATE_DIR/containerd.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
sudo install -m 644 "$STATE_DIR/containerd.toml" "$ETC/containerd.toml"

echo "[setup] the kubelet's configuration for this node (cgroupDriver cgroupfs, as in the question), its pod manifests and the kubelet program..."
cat > "$STATE_DIR/kubelet-config.yaml" <<YAML
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
cgroupDriver: cgroupfs
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
containerRuntimeEndpoint: unix://$T_SOCK
rotateCertificates: true
staticPodPath: $ETC/manifests
YAML
sudo install -m 644 "$STATE_DIR/kubelet-config.yaml" "$ETC/kubelet-config.yaml"
python3 "$STATE_DIR/lab.py" manifests "$STATE_DIR/manifests"
sudo cp "$STATE_DIR"/manifests/*.json "$ETC/manifests/"
sudo chmod 644 "$ETC"/manifests/*.json
sudo install -m 755 "$STATE_DIR/kubelet-sim" "$LIB_BASE/bin/kubelet-sim"
sudo chmod 755 "$LIB_BASE" "$ETC" "$ETC/manifests" "$LIB_BASE/bin"
sha256sum "$STATE_DIR"/patch_config.py "$STATE_DIR"/mkimg.py "$STATE_DIR"/lab.py "$STATE_DIR"/verify.py "$STATE_DIR"/kubelet-sim "$STATE_DIR"/app.c "$STATE_DIR"/pause.c \
    | awk '{print $1}' > "$STATE_DIR/helpers.sha"
sha256sum "$ETC/containerd.toml" | awk '{print $1}' > "$STATE_DIR/containerd.toml.sha"

echo "[setup] starting the node's containerd (own socket $T_SOCK, configuration $ETC/containerd.toml)..."
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$ETC/containerd.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
UP=""
for _ in $(seq 1 80); do
    if [ -S "$T_SOCK" ] && "${CRI[@]}" version >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: the node's containerd did not come up:"; sudo tail -5 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] importing the images (offline) into the 'k8s.io' namespace..."
python3 "$STATE_DIR/lab.py" images "$T_SOCK" "$WORK_DIR" || { echo "[setup] ERROR: the images were not imported"; exit 1; }

echo "[setup] the kubelet starts the node's pods once (its log: $LIB_BASE/kubelet.log)..."
sudo "$LIB_BASE/bin/kubelet-sim" sync || true

echo "[setup] done. Node: containerd ($T_SOCK, $ETC/containerd.toml), kubelet configuration $ETC/kubelet-config.yaml, pod manifests in $ETC/manifests, kubelet program $LIB_BASE/bin/kubelet-sim (sync, status)."
