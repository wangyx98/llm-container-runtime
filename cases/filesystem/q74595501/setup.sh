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

CASE_ID="bench74595501"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/bench74595501-app:latest"

echo "[setup] checking containerd and its ctr client are installed (the runtime"
echo "[setup] under test; same assumption as the other containerd cases)..."
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

echo "[setup] ensuring gcc is available (only to compile the tiny fixed program that is"
echo "[setup] the image's entrypoint)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure containerd runs with its default config (this enables"
echo "[setup] its CRI plugin, which a Docker-packaged containerd.io ships"
echo "[setup] disabled)..."
# Restart containerd ONLY when it has to change. systemd refuses a unit that
# is started more than 5 times within 10 seconds ("Start request repeated too
# quickly"), and a benchmark run executes this setup once per sample, one
# sample after another.
sudo mkdir -p /etc/containerd
DEFAULT_CFG=$(mktemp)
containerd config default > "$DEFAULT_CFG"
if sudo cmp -s "$DEFAULT_CFG" /etc/containerd/config.toml \
   && sudo systemctl is-active --quiet containerd \
   && $CRICTL info >/dev/null 2>&1; then
    echo "[setup] containerd already runs with the default config and its CRI is"
    echo "[setup] answering; no restart needed."
else
    sudo install -m 0644 "$DEFAULT_CFG" /etc/containerd/config.toml
    echo "[setup] (re)starting containerd so the default config takes effect..."
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
mkdir -p "$STATE_DIR"

echo "[setup] compiling the image's entrypoint: a static program that prints one line"
echo "[setup] containing a per-run random token and exits. The token exists only in"
echo "[setup] this image, so seeing it in the output of a container proves the"
echo "[setup] container runs THIS image."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>

int main(void) {
    puts("bench74595501-app token=" TOKEN);
    return 0;
}
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/app" "$STATE_DIR/app.c"

echo "[setup] writing the image as a tarball in 'docker save' layout (manifest.json +"
echo "[setup] config blob + one layer), tagged $IMAGE_REF..."
cat > "$STATE_DIR/mkimage.py" <<'PYEOF'
import hashlib
import io
import json
import sys
import tarfile

out, binary, tag, arch = sys.argv[1:5]

layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    data = open(binary, "rb").read()
    ti = tarfile.TarInfo("app")
    ti.size, ti.mode, ti.mtime, ti.uid, ti.gid = len(data), 0o755, 0, 0, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": arch,
    "os": "linux",
    "created": "1970-01-01T00:00:00Z",
    "config": {"Cmd": ["/app"]},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench74595501"}],
}, sort_keys=True, separators=(",", ":")).encode()
image_id = hashlib.sha256(config).hexdigest()

manifest = json.dumps([{
    "Config": image_id + ".json",
    "RepoTags": [tag],
    "Layers": [diff_id + "/layer.tar"],
}]).encode()


def add(t, name, payload):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
    t.addfile(ti, io.BytesIO(payload))


with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff_id)
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
    t.addfile(d)
    add(t, diff_id + "/layer.tar", layer)
    add(t, image_id + ".json", config)
    add(t, "manifest.json", manifest)

# An image's ID, as the CRI reports it, is the sha256 of its config blob.
print(image_id)
PYEOF
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/app.tar" "$STATE_DIR/app" "$IMAGE_REF" "$IMG_ARCH")
chmod 0644 "$STATE_DIR/app.tar"
echo "$TOKEN" > "$STATE_DIR/token"
echo "$IMAGE_ID" > "$STATE_DIR/image_id"
echo "  -> image id sha256:$IMAGE_ID"

echo "[setup] importing it into containerd's 'default' namespace, which is where a plain"
echo "[setup] 'ctr images import' puts it (the CRI, and so Kubernetes, uses 'k8s.io')..."
sudo ctr -n default images import "$STATE_DIR/app.tar" >/dev/null

echo "[setup] removing the tarball, the generator, the source and the binary: the only"
echo "[setup] copy of the image is the one inside containerd's default namespace now,"
echo "[setup] as in the question, where the archive was deleted to save disk space..."
rm -f "$STATE_DIR/app.tar" "$STATE_DIR/mkimage.py" "$STATE_DIR/app.c" "$STATE_DIR/app"

echo "[setup] done. 'ctr -n default images ls' lists $IMAGE_REF;"
echo "[setup] 'ctr -n k8s.io images ls' and 'crictl images' do not."
