#!/bin/bash
set -e

# Ubuntu 22.04/24.04 ship `needrestart`, which pops up an interactive
# whiptail dialog whenever apt upgrades a shared library as a dependency.
# Force both apt's own prompts and needrestart into non-interactive mode
# (same workaround used by the other cases in this benchmark).
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CRICTL_VERSION="v1.34.0"
SOCK="/run/containerd/containerd.sock"
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"

CASE_ID="bench74562978"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
REGISTRY_DIR="$WORK_DIR/registry"
REGISTRY_PORT=25562
REGISTRY_HOST="registry.bench74562978.test"
REPO="$CASE_ID/app"
IMAGE_REF="$REGISTRY_HOST:$REGISTRY_PORT/$REPO:latest"

echo "[setup] checking containerd and its ctr client are installed (the"
echo "[setup] runtime under test; same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
containerd --version

echo "[setup] ensuring crictl is installed (CRI client for containerd)..."
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64"; IMG_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64"; IMG_ARCH="arm64" ;;
    armv7l|armhf)   CRICTL_ARCH="arm"; IMG_ARCH="arm" ;;
    ppc64le)        CRICTL_ARCH="ppc64le"; IMG_ARCH="ppc64le" ;;
    s390x)          CRICTL_ARCH="s390x"; IMG_ARCH="s390x" ;;
    *)              CRICTL_ARCH="amd64"; IMG_ARCH="amd64" ;;
esac
if ! command -v crictl >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl ca-certificates
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
command -v crictl
crictl --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure containerd runs with its default config (CRI plugin on; a"
echo "[setup] Docker-packaged containerd.io ships it disabled), with the CRI reading"
echo "[setup] per-registry settings from /etc/containerd/certs.d like a kind/kubeadm node..."
# Restart containerd ONLY when it has to change. systemd refuses a unit that
# is started more than 5 times within 10 seconds ("Start request repeated too
# quickly"), and a benchmark run executes this setup once per sample, one
# sample after another.
# The baseline is containerd's default config with every config_path pointed
# at /etc/containerd/certs.d. containerd 1.6 - 2.0 and 2.2.3 default it to empty
# and 2.1 - 2.2.1 to "/etc/containerd/certs.d:/etc/docker/certs.d"; fixing it
# makes the starting point the same on every version.
sudo mkdir -p /etc/containerd
DEFAULT_CFG=$(mktemp)
containerd config default 2>/dev/null \
    | sed -E "s|^([[:space:]]*config_path[[:space:]]*=[[:space:]]*)(['\"]).*\2[[:space:]]*$|\1\2/etc/containerd/certs.d\2|" > "$DEFAULT_CFG"
if sudo cmp -s "$DEFAULT_CFG" /etc/containerd/config.toml \
   && sudo systemctl is-active --quiet containerd \
   && $CRICTL info >/dev/null 2>&1; then
    echo "[setup] containerd already runs with the baseline config and its CRI is"
    echo "[setup] answering; no restart needed."
else
    sudo install -m 0644 "$DEFAULT_CFG" /etc/containerd/config.toml
    echo "[setup] (re)starting containerd so the baseline config takes effect..."
    sudo systemctl reset-failed containerd 2>/dev/null || true   # clears a start-limit hit
    sudo systemctl restart containerd
fi
rm -f "$DEFAULT_CFG"
for _ in $(seq 1 20); do
    [ -S "$SOCK" ] && break
    sleep 0.5
done
sudo systemctl is-active containerd

echo "[setup] pointing crictl at containerd's CRI socket..."
cat <<YEOF | sudo tee /etc/crictl.yaml > /dev/null
runtime-endpoint: unix://$SOCK
image-endpoint: unix://$SOCK
timeout: 10
debug: false
YEOF
$CRICTL info >/dev/null

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$REGISTRY_DIR/blobs"
sudo mkdir -p "$RUN_DIR"

echo "[setup] building the image the registry will serve (one small layer carrying a"
echo "[setup] per-run random token) as an OCI image: manifest + config + layer blob..."
python3 - "$REGISTRY_DIR" "$STATE_DIR" "$REPO" "$IMG_ARCH" <<'PYEOF'
import gzip, hashlib, io, json, os, secrets, sys, tarfile

registry, state, repo, arch = sys.argv[1:5]
token = secrets.token_hex(8)

raw = io.BytesIO()
with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as t:
    data = ("bench74562978 token=%s\n" % token).encode()
    ti = tarfile.TarInfo("bench74562978.txt")
    ti.size, ti.mode, ti.mtime = len(data), 0o644, 0
    t.addfile(ti, io.BytesIO(data))
layer_tar = raw.getvalue()
diff_id = "sha256:" + hashlib.sha256(layer_tar).hexdigest()
layer_gz = gzip.compress(layer_tar, mtime=0)
layer_digest = "sha256:" + hashlib.sha256(layer_gz).hexdigest()

config = json.dumps({
    "architecture": arch, "os": "linux",
    "config": {"Cmd": ["/bin/true"]},
    "rootfs": {"type": "layers", "diff_ids": [diff_id]},
    "history": [{"created_by": "bench74562978"}],
}, sort_keys=True, separators=(",", ":")).encode()
config_digest = "sha256:" + hashlib.sha256(config).hexdigest()

OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
manifest = json.dumps({
    "schemaVersion": 2,
    "mediaType": OCI_MANIFEST,
    "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
               "digest": config_digest, "size": len(config)},
    "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                "digest": layer_digest, "size": len(layer_gz)}],
}, sort_keys=True, separators=(",", ":")).encode()
manifest_digest = "sha256:" + hashlib.sha256(manifest).hexdigest()

blobs = {}
for digest, body in ((config_digest, config), (layer_digest, layer_gz)):
    rel = "blobs/" + digest.split(":")[1]
    open(os.path.join(registry, rel), "wb").write(body)
    blobs[digest] = rel
open(os.path.join(registry, "manifest.json"), "wb").write(manifest)
json.dump({"repo": repo, "tag": "latest",
           "manifest": {"digest": manifest_digest, "type": OCI_MANIFEST, "file": "manifest.json"},
           "blobs": blobs}, open(os.path.join(registry, "index.json"), "w"))

# the CRI reports an image's ID as the digest of its config blob
open(os.path.join(state, "expected_image_id"), "w").write(config_digest.split(":")[1] + "\n")
open(os.path.join(state, "layer_digest"), "w").write(layer_digest + "\n")
PYEOF

echo "[setup] giving the registry a host name ($REGISTRY_HOST -> 127.0.0.1) in /etc/hosts."
echo "[setup] (A name, not an address: containerd allows plain HTTP to loopback"
echo "[setup] addresses and to 'localhost' on its own, but not to other host names.)"
echo "127.0.0.1 $REGISTRY_HOST # $CASE_ID" | sudo tee -a /etc/hosts >/dev/null

echo "[setup] starting the registry on 127.0.0.1:$REGISTRY_PORT (plain HTTP only, request log kept)..."
if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(('127.0.0.1', $REGISTRY_PORT))==0 else 1)"; then
    echo "[setup] ERROR: something else already listens on 127.0.0.1:$REGISTRY_PORT"
    exit 1
fi
: > "$STATE_DIR/registry.log"
# setsid + all three fds redirected: the daemon must outlive this script and
# must not keep the harness's stdout/stderr pipes open; exec keeps the pid
sudo setsid -f bash -c 'echo $$ > "$1"; shift; exec "$@" >/dev/null 2>&1 </dev/null' \
    _ "$RUN_DIR/registry.pid" \
    python3 "$CASE_DIR/registry_server.py" --dir "$REGISTRY_DIR" --port "$REGISTRY_PORT" --log "$STATE_DIR/registry.log" \
    </dev/null >/dev/null 2>&1
for _ in $(seq 1 20); do
    python3 - "$REGISTRY_PORT" 2>/dev/null <<'PYEOF' && break
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/v2/" % sys.argv[1], timeout=2).read()
PYEOF
    sleep 0.5
done
: > "$STATE_DIR/registry.log"   # forget the readiness probes above
if ! python3 - "$REGISTRY_PORT" "$REPO" <<'PYEOF'
import sys, urllib.request
r = urllib.request.urlopen("http://127.0.0.1:%s/v2/%s/manifests/latest" % (sys.argv[1], sys.argv[2]), timeout=2)
assert r.status == 200
PYEOF
then
    echo "[setup] ERROR: the registry does not serve the image"
    exit 1
fi
: > "$STATE_DIR/registry.log"
echo "  -> registry up, serving $REPO:latest"

echo "[setup] trying to pull $IMAGE_REF through the CRI (EXPECTED to"
echo "[setup] fail: containerd assumes HTTPS for this host, the registry only speaks HTTP)..."
if timeout 90 $CRICTL -t 60s pull "$IMAGE_REF" >"$STATE_DIR/first_pull.out" 2>&1; then
    echo "[setup] FAIL: the pull unexpectedly succeeded; the scenario is not broken"
    exit 1
fi
head -c 300 "$STATE_DIR/first_pull.out" | head -2 | sed 's/^/  -> /'
echo
: > "$STATE_DIR/registry.log"

echo "[setup] done. The registry holds the image; containerd refuses to talk plain HTTP to it."
