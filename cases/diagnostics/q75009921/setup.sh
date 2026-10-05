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
CASE_ID="bench75009921"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
NS_A="$CASE_ID-a"
NS_B="$CASE_ID-b"

echo "[setup] checking containerd, its ctr client (used here to build the scenario and by the"
echo "[setup] oracle as ground truth), curl with HTTP/2 and python3 are installed..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v curl >/dev/null || { echo "[setup] ERROR: curl not found"; exit 1; }
curl --version | grep -qw HTTP2 || { echo "[setup] ERROR: this curl has no HTTP/2 support"; exit 1; }
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }
containerd --version

echo "[setup] ensuring gcc is available (only to compile the small fixed program that is"
echo "[setup] the one program of the image)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

case "$(uname -m)" in
    x86_64|amd64)   IMG_ARCH="amd64" ;;
    aarch64|arm64)  IMG_ARCH="arm64" ;;
    armv7l|armhf)   IMG_ARCH="arm" ;;
    ppc64le)        IMG_ARCH="ppc64le" ;;
    s390x)          IMG_ARCH="s390x" ;;
    *)              IMG_ARCH="amd64" ;;
esac

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure containerd is running..."
# Do not restart it here: this case does not use the CRI, so the default config
# is not needed, and a benchmark run executes this setup once per sample.
if ! sudo ctr version >/dev/null 2>&1; then
    sudo systemctl reset-failed containerd 2>/dev/null || true   # clears a start-limit hit
    sudo systemctl start containerd
fi
for _ in $(seq 1 20); do
    [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo ctr version >/dev/null

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
cd "$WORK_DIR"

TOK=$(python3 -c 'import secrets; print(secrets.token_hex(3))')
echo "$TOK" > "$STATE_DIR/token"

echo "[setup] compiling the workload program (starts, prints one line, sleeps)..."
cat > "$STATE_DIR/workload.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
    puts("workload: started");
    fflush(stdout);
    for (;;)
        sleep(3600);
}
CEOF
gcc -static -Os -s -w -o "$STATE_DIR/workload" "$STATE_DIR/workload.c"

echo "[setup] writing the image in 'docker save' layout (manifest.json + config blob + one"
echo "[setup] layer holding /usr/bin/workload)..."
cat > "$STATE_DIR/mkimage.py" <<'PYEOF'
import hashlib
import io
import json
import sys
import tarfile

out, binary, tag, arch = sys.argv[1:5]
data = open(binary, "rb").read()

layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    for d in ("usr", "usr/bin"):
        ti = tarfile.TarInfo(d)
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 0
        lt.addfile(ti)
    ti = tarfile.TarInfo("usr/bin/workload")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": arch,
    "os": "linux",
    "created": "1970-01-01T00:00:00Z",
    "config": {"Cmd": ["/usr/bin/workload"]},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench75009921"}],
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

print(image_id)
PYEOF
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/app.tar" "$STATE_DIR/workload" "$IMAGE_REF" "$IMG_ARCH")
chmod 0644 "$STATE_DIR/app.tar"
echo "$IMAGE_ID" > "$STATE_DIR/image_id"

echo "[setup] importing the image into the three namespaces that get containers (images are"
echo "[setup] per namespace in containerd)..."
for ns in default "$NS_A" "$NS_B"; do
    sudo ctr -n "$ns" images import "$STATE_DIR/app.tar" >/dev/null
    sudo ctr -n "$ns" images ls -q | grep -qFx "$IMAGE_REF" || { echo "[setup] ERROR: $IMAGE_REF missing in namespace $ns"; exit 1; }
    echo "  -> $ns"
done
rm -f "$STATE_DIR/app.tar" "$STATE_DIR/mkimage.py" "$STATE_DIR/workload.c" "$STATE_DIR/workload"

echo "[setup] creating the containers: some running (a task), some only created; one ID is used in"
echo "[setup] two namespaces..."
make_container() {   # $1 namespace, $2 id suffix, $3 "run" to also start it
    local id="$CASE_ID-$TOK-$2"
    sudo ctr -n "$1" containers create "$IMAGE_REF" "$id" >/dev/null
    if [ "$3" = "run" ]; then
        timeout -k 5 60 sudo ctr -n "$1" tasks start -d "$id" </dev/null >/dev/null 2>&1
    fi
    echo "  -> $1 $id ($([ "$3" = run ] && echo running || echo created))"
}
make_container default  drun   run
make_container default  didle  no
make_container "$NS_A"  arun   run
make_container "$NS_A"  shared no
make_container "$NS_B"  bidle  no
make_container "$NS_B"  shared no

# the ground truth the oracle compares with: "<namespace> <container id>" for every container of
# containerd (not only this case's), taken now, and again by the oracle through ctr
echo "[setup] recording the list of containers (namespace and id) before the solution runs..."
for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
    for c in $(sudo ctr -n "$ns" containers ls -q 2>/dev/null); do
        echo "$ns $c"
    done
done | LC_ALL=C sort > "$STATE_DIR/containers.truth"
echo "  -> $(wc -l < "$STATE_DIR/containers.truth") containers in $(cut -d' ' -f1 "$STATE_DIR/containers.truth" | sort -u | wc -l) namespaces"

echo "[setup] done. The containers exist; /tmp/$CASE_ID/containers.txt is not there yet."
