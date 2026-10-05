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
CASE_ID="bench70105718"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
LOG_DIR="/var/log/$CASE_ID"

echo "[setup] checking containerd, its ctr client and runc (the runtime under test) are installed..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }
containerd --version
runc --version | head -n 1

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

echo "[setup] clearing leftovers from a previous run (idempotency; this also puts runc back if a"
echo "[setup] previous run left a wrapper in its place)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure the runc found on the PATH is the real binary and not a leftover wrapper..."
RUNC_BIN=$(sudo bash -c 'command -v runc')
if ! sudo python3 - "$RUNC_BIN" <<'PYEOF'
import os, sys
p = os.path.realpath(sys.argv[1])
sys.exit(0 if open(p, "rb").read(4) == b"\x7fELF" else 1)
PYEOF
then
    echo "[setup] ERROR: $RUNC_BIN is not an executable binary (a script?); put the real runc back and run again"
    exit 1
fi
echo "  -> $RUNC_BIN"

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

# A solution may put a wrapper where the real runc is (a common way to add --debug for every
# container). cleanup.sh puts every runc* file of the usual binary directories back to what it is
# now, so the machine's real runc is never left replaced: take that snapshot here.
echo "[setup] taking a snapshot of the runc* files in the binary directories (cleanup.sh restores it)..."
sudo python3 - "$STATE_DIR" <<'PYEOF'
import hashlib, json, os, shutil, sys

state = sys.argv[1]
backup_dir = os.path.join(state, "runc_backup")
os.makedirs(backup_dir, exist_ok=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


dirs, entries = [], []
for d in ("/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"):
    rd = os.path.realpath(d)
    if rd in dirs or not os.path.isdir(rd):
        continue
    dirs.append(rd)
    for name in sorted(os.listdir(rd)):
        if not name.startswith("runc"):
            continue
        p = os.path.join(rd, name)
        if os.path.islink(p):
            entries.append({"path": p, "type": "link", "target": os.readlink(p)})
        elif os.path.isfile(p):
            b = os.path.join(backup_dir, str(len(entries)))
            shutil.copy2(p, b)
            entries.append({"path": p, "type": "file", "sha256": sha256(p), "backup": b,
                            "mode": os.stat(p).st_mode & 0o7777})
json.dump({"dirs": dirs, "entries": entries}, open(os.path.join(state, "runc_snapshot.json"), "w"))
for e in entries:
    print("  ->", e["path"], e["type"])
PYEOF

echo "[setup] creating the (empty) log directory $LOG_DIR ..."
if [ ! -d "$LOG_DIR" ]; then
    sudo mkdir -p "$LOG_DIR"
    touch "$STATE_DIR/log_dir_created"
fi

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
echo "[setup] layer holding /usr/bin/workload, which is the image's default command)..."
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
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench70105718"}],
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

echo "[setup] importing it into containerd's 'default' namespace (there is no registry to"
echo "[setup] pull this private image from)..."
sudo ctr images import "$STATE_DIR/app.tar" >/dev/null
rm -f "$STATE_DIR/app.tar" "$STATE_DIR/mkimage.py" "$STATE_DIR/workload.c" "$STATE_DIR/workload"
sudo ctr images ls -q | grep -qFx "$IMAGE_REF" || { echo "[setup] ERROR: containerd does not list $IMAGE_REF"; exit 1; }
echo "  -> $IMAGE_REF"

echo "[setup] done. The image is imported, no container exists, and $LOG_DIR is empty."
