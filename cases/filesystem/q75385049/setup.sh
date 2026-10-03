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

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75385049"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
TARBALL="$WORK_DIR/hello.tar"

echo "[setup] checking containerd and its ctr client are installed (the runtime"
echo "[setup] under test; same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
containerd --version

echo "[setup] ensuring gcc is available (only to compile the tiny fixed program that is"
echo "[setup] the image's entrypoint)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure containerd runs..."
sudo systemctl is-active --quiet containerd || {
    sudo systemctl reset-failed containerd 2>/dev/null || true
    sudo systemctl start containerd
}
for _ in $(seq 1 20); do
    [ -S "$SOCK" ] && break
    sleep 0.5
done
sudo ctr version >/dev/null

case "$(uname -m)" in
    x86_64|amd64)   IMG_ARCH="amd64" ;;
    aarch64|arm64)  IMG_ARCH="arm64" ;;
    armv7l|armhf)   IMG_ARCH="arm" ;;
    ppc64le)        IMG_ARCH="ppc64le" ;;
    s390x)          IMG_ARCH="s390x" ;;
    *)              IMG_ARCH="amd64" ;;
esac

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"

echo "[setup] compiling the image's entrypoint: a static program that prints one line"
echo "[setup] containing a per-run random token and exits. The token exists only in"
echo "[setup] this archive, so seeing it in the output of a container proves the"
echo "[setup] container runs THIS image."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
cat > "$STATE_DIR/hello.c" <<'CEOF'
#include <stdio.h>

int main(void) {
    puts("bench75385049-hello token=" TOKEN);
    return 0;
}
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/hello" "$STATE_DIR/hello.c"

echo "[setup] writing the archive the way 'skopeo copy docker://... docker-archive:hello.tar'"
echo "[setup] does when the destination names no image: a docker-archive (manifest.json +"
echo "[setup] config blob + one layer) whose manifest.json has an EMPTY RepoTags list..."
cat > "$STATE_DIR/mkimage.py" <<'PYEOF'
import hashlib
import io
import json
import sys
import tarfile

out, binary, arch = sys.argv[1:4]

layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    data = open(binary, "rb").read()
    ti = tarfile.TarInfo("hello")
    ti.size, ti.mode, ti.mtime, ti.uid, ti.gid = len(data), 0o755, 0, 0, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": arch,
    "os": "linux",
    "created": "1970-01-01T00:00:00Z",
    "config": {"Cmd": ["/hello"]},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench75385049"}],
}, sort_keys=True, separators=(",", ":")).encode()
image_id = hashlib.sha256(config).hexdigest()

manifest = json.dumps([{
    "Config": image_id + ".json",
    "RepoTags": [],
    "Layers": [diff_id + ".tar"],
}]).encode()


def add(t, name, payload):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
    t.addfile(ti, io.BytesIO(payload))


with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    add(t, diff_id + ".tar", layer)
    add(t, image_id + ".json", config)
    add(t, "manifest.json", manifest)

print(image_id)
PYEOF
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$TARBALL" "$STATE_DIR/hello" "$IMG_ARCH")
chmod 0644 "$TARBALL"
echo "$TOKEN" > "$STATE_DIR/token"
echo "$IMAGE_ID" > "$STATE_DIR/image_id"
echo "  -> $TARBALL (image id sha256:$IMAGE_ID)"

echo "[setup] removing the generator, the source and the binary, so the archive is the"
echo "[setup] only copy of the image..."
rm -f "$STATE_DIR/mkimage.py" "$STATE_DIR/hello.c" "$STATE_DIR/hello"

echo "[setup] done. containerd has no image from this archive in any namespace."
