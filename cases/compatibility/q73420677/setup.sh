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

WORK_DIR="/tmp/bench73420677"
STATE_DIR="$WORK_DIR/.bench"
TARBALL="$WORK_DIR/app.tar"
POD_CONFIG="$WORK_DIR/pod-config.json"
CONTAINER_CONFIG="$WORK_DIR/container-config.json"
DOCKER_TAG="bench73420677-app:latest"
POD_NAME="bench73420677-pod"
CONTAINER_NAME="bench73420677"

echo "[setup] checking containerd and its ctr client are installed (the"
echo "[setup] runtime under test; same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
containerd --version

echo "[setup] ensuring crictl is installed (CRI client for containerd)..."
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    armv7l|armhf)   CRICTL_ARCH="arm" ;;
    ppc64le)        CRICTL_ARCH="ppc64le" ;;
    s390x)          CRICTL_ARCH="s390x" ;;
    *)              CRICTL_ARCH="amd64" ;;
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

echo "[setup] ensuring gcc is available (only to compile the small fixed"
echo "[setup] long-running program that goes into the image, so the same"
echo "[setup] script works on x86_64 and arm64 hosts)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure containerd runs with its default config (this enables"
echo "[setup] its CRI plugin, which a Docker-packaged containerd.io ships"
echo "[setup] disabled)..."
# Restart containerd ONLY when it has to change. systemd refuses a unit that
# is started more than 5 times within 10 seconds ("Start request repeated too
# quickly"), and a benchmark run executes this setup once per sample, one
# sample after another. Restarting unconditionally therefore made the 6th
# back-to-back sample fail in setup, long before its solution even ran.
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

echo "[setup] making sure containerd already has its pod sandbox (pause) image,"
echo "[setup] so starting a pod does not depend on a registry round trip..."
# containerd 2.x calls the key `sandbox = '...'`, 1.x calls it
# `sandbox_image = "..."`; accept both spellings and either quote style.
PAUSE_IMAGE=$(sudo containerd config dump 2>/dev/null \
    | sed -nE "s/^[[:space:]]*sandbox(_image)?[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\2/p" | head -1)
if [ -n "$PAUSE_IMAGE" ]; then
    $CRICTL pull "$PAUSE_IMAGE" >/dev/null 2>&1 \
        || echo "[setup] note: could not pull $PAUSE_IMAGE now (it may already be cached)"
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/logs"
cd "$WORK_DIR"

case "$(uname -m)" in
    x86_64|amd64)   IMG_ARCH="amd64" ;;
    aarch64|arm64)  IMG_ARCH="arm64" ;;
    armv7l|armhf)   IMG_ARCH="arm" ;;
    ppc64le)        IMG_ARCH="ppc64le" ;;
    s390x)          IMG_ARCH="s390x" ;;
    *)              IMG_ARCH="amd64" ;;
esac

echo "[setup] compiling the image's entrypoint: a static program that prints"
echo "[setup] a line containing a per-run random token once a second. The"
echo "[setup] token exists only inside this image, so seeing it in the"
echo "[setup] container's log proves the container runs THIS image."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(6))')
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <time.h>

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        puts("bench73420677-image-ok token=" TOKEN);
        fflush(stdout);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/bench-app" "$STATE_DIR/app.c"

echo "[setup] writing the tarball the way 'docker save' lays it out"
echo "[setup] (manifest.json + config blob + one layer), tagged $DOCKER_TAG..."
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
    ti = tarfile.TarInfo("bench-app")
    ti.size, ti.mode, ti.mtime, ti.uid, ti.gid = len(data), 0o755, 0, 0, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": arch,
    "os": "linux",
    "created": "1970-01-01T00:00:00Z",
    "config": {"Entrypoint": ["/bench-app"], "WorkingDir": "/"},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench73420677"}],
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
# Print it so setup can record what the oracle must find later.
print(image_id)
PYEOF
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$TARBALL" "$STATE_DIR/bench-app" "$DOCKER_TAG" "$IMG_ARCH")
chmod 0644 "$TARBALL"
echo "$TOKEN" > "$STATE_DIR/token"
echo "$IMAGE_ID" > "$STATE_DIR/expected_image_id"
sha256sum "$TARBALL" | awk '{print $1}' > "$STATE_DIR/tarball.sha256"
echo "  -> tarball: $TARBALL ($(stat -c %s "$TARBALL") bytes), image id sha256:$IMAGE_ID"

echo "[setup] loading the tarball with plain 'ctr images import'. ctr puts"
echo "[setup] images into ITS OWN default namespace ('default'); this is how a"
echo "[setup] colleague following the usual 'import it into containerd' advice"
echo "[setup] would have loaded it. 'ctr images ls' shows the image, which is"
echo "[setup] exactly the 'but the image exists!' part of the bug report..."
sudo ctr -n default images import "$TARBALL" >/dev/null

echo "[setup] writing the workload: a pod sandbox config and a container config"
echo "[setup] whose image is referenced by its plain local name. The CRI never"
echo "[setup] pulls when a container is created from an existing sandbox, the"
echo "[setup] same as a Kubernetes pod with imagePullPolicy: Never..."
cat > "$POD_CONFIG" <<PEOF
{
  "metadata": {
    "name": "$POD_NAME",
    "namespace": "default",
    "attempt": 1,
    "uid": "bench73420677uid00000001"
  },
  "log_directory": "$WORK_DIR/logs",
  "linux": {
    "security_context": {
      "namespace_options": {
        "network": 2
      }
    }
  }
}
PEOF
cat > "$CONTAINER_CONFIG" <<CEOF2
{
  "metadata": {
    "name": "$CONTAINER_NAME"
  },
  "image": {
    "image": "$DOCKER_TAG"
  },
  "log_path": "$CONTAINER_NAME.0.log",
  "linux": {}
}
CEOF2

echo "[setup] starting the pod sandbox (the 'scheduled' pod)..."
POD_ID=$($CRICTL runp "$POD_CONFIG")
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "  -> pod sandbox $POD_ID"

echo "[setup] trying to create the container in it (this is EXPECTED to fail:"
echo "[setup] the CRI looks in its own namespace, k8s.io, not in 'default')..."
if $CRICTL create "$POD_ID" "$CONTAINER_CONFIG" "$POD_CONFIG" > "$STATE_DIR/first_attempt.out" 2>&1; then
    echo "[setup] FAIL: container creation unexpectedly succeeded; the scenario is not broken"
    exit 1
fi
sed 's/^/  -> /' "$STATE_DIR/first_attempt.out" | tail -3

echo "[setup] done. The pod sandbox is Ready, 'ctr images ls' lists the image,"
echo "[setup] but the container cannot be created from it."
