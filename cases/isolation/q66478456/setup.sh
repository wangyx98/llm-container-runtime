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
CASE_ID="bench66478456"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
CONTAINER_NAME="$CASE_ID"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
HOST_ID=5000

echo "[setup] checking containerd and its ctr client are installed (the"
echo "[setup] runtime under test; same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
containerd --version

echo "[setup] checking the kernel lets root create user namespaces (what --uidmap needs)..."
if ! unshare -U true 2>/dev/null && ! sudo unshare -U true 2>/dev/null; then
    echo "[setup] ERROR: this kernel does not allow user namespaces (user.max_user_namespaces=0?)"
    exit 1
fi

echo "[setup] ensuring gcc is available (only to compile the small fixed program that is"
echo "[setup] every executable of the image)..."
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
mkdir -p "$STATE_DIR" "$DATA_DIR"
cd "$WORK_DIR"

TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
echo "$TOKEN" > "$STATE_DIR/token"

echo "[setup] compiling the program. As 'idle' it writes /data/inside.txt (the uid and gid it"
echo "[setup] runs as, a per-run token and the time in nanoseconds; written to a temp file and"
echo "[setup] renamed, so an older file owned by someone else does not stop it) and then idles."
echo "[setup] As 'id' it prints the uid and gid it runs as..."
cat > "$STATE_DIR/tool.c" <<'CEOF'
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    const char *base = strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    unsigned uid = geteuid(), gid = getegid();
    if (strcmp(base, "id") == 0) {
        printf("uid=%u gid=%u\n", uid, gid);
        return 0;
    }
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    char line[256];
    int n = snprintf(line, sizeof line, "uid=%u\ngid=%u\ntoken=" TOKEN "\nts=%lld\n",
                     uid, gid, (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec);
    int fd = open("/data/inside.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        if (write(fd, line, n) == n && close(fd) == 0)
            rename("/data/inside.tmp", "/data/inside.txt");
    }
    for (;;) pause();
}
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/tool" "$STATE_DIR/tool.c"

echo "[setup] writing the image in 'docker save' layout (manifest.json + config blob + one"
echo "[setup] layer holding /usr/bin/idle, /usr/bin/id and an empty /data)..."
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
    for d in ("usr", "usr/bin", "data"):
        ti = tarfile.TarInfo(d)
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 0
        lt.addfile(ti)
    for name in ("idle", "id"):
        ti = tarfile.TarInfo("usr/bin/" + name)
        ti.size, ti.mode, ti.mtime = len(data), 0o755, 0
        lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": arch,
    "os": "linux",
    "created": "1970-01-01T00:00:00Z",
    "config": {"Cmd": ["/usr/bin/idle"]},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench66478456"}],
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
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/app.tar" "$STATE_DIR/tool" "$IMAGE_REF" "$IMG_ARCH")
chmod 0644 "$STATE_DIR/app.tar"
echo "$IMAGE_ID" > "$STATE_DIR/image_id"

echo "[setup] importing it into containerd's 'default' namespace (there is no registry to"
echo "[setup] pull this private image from)..."
sudo ctr images import "$STATE_DIR/app.tar" >/dev/null
rm -f "$STATE_DIR/app.tar" "$STATE_DIR/mkimage.py" "$STATE_DIR/tool.c" "$STATE_DIR/tool"
sudo ctr images ls -q | grep -qFx "$IMAGE_REF" || { echo "[setup] ERROR: containerd does not list $IMAGE_REF"; exit 1; }
echo "  -> $IMAGE_REF"

echo "[setup] creating the host data dir $DATA_DIR, owned by $HOST_ID:$HOST_ID (a uid and gid"
echo "[setup] that do not exist in any /etc/passwd)..."
sudo chown "$HOST_ID:$HOST_ID" "$DATA_DIR"
sudo chmod 0755 "$DATA_DIR"

echo "[setup] starting the engineer's container: --uidmap given, --gidmap forgotten..."
timeout -k 5 60 sudo ctr run -d \
    --uidmap "0:$HOST_ID:4999" \
    --mount "type=bind,src=$DATA_DIR,dst=/data,options=rbind:rw" \
    "$IMAGE_REF" "$CONTAINER_NAME" </dev/null

echo "[setup] waiting until it runs and has written /data/inside.txt..."
PID=""
for _ in $(seq 1 40); do
    PID=$(sudo ctr tasks ls 2>/dev/null | awk -v n="$CONTAINER_NAME" '$1==n && $3=="RUNNING" {print $2}')
    [ -n "$PID" ] && [ -f "$DATA_DIR/inside.txt" ] && break
    sleep 0.5
done
[ -n "$PID" ] && [ -f "$DATA_DIR/inside.txt" ] || { echo "[setup] ERROR: the container did not start"; exit 1; }
echo "$PID" > "$STATE_DIR/pid"
date +%s%N > "$STATE_DIR/t0"
echo "  -> host pid $PID"

echo "[setup] done. Container $CONTAINER_NAME runs; its main process is root on the host (no"
echo "[setup] user namespace), and $DATA_DIR/inside.txt belongs to root."
