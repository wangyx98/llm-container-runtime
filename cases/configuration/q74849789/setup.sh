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

CASE_ID="bench74849789"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
POD_NAME="$CASE_ID-pod"
CONTAINER_NAME="$CASE_ID"
IMAGE_TAG="$CASE_ID-app:latest"
INITIAL_LIMIT=134217728     # 128 MiB, what the container starts with

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

echo "[setup] ensuring gcc is available (only to compile the small fixed"
echo "[setup] program that is the workload container's entrypoint)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure containerd runs with its CRI answering..."
sudo systemctl is-active --quiet containerd || {
    sudo systemctl reset-failed containerd 2>/dev/null || true
    sudo systemctl start containerd
}
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
mkdir -p "$STATE_DIR" "$DATA_DIR" "$WORK_DIR/logs"
cd "$WORK_DIR"

echo "[setup] compiling the workload: a static program that allocates and touches"
echo "[setup] 48 MiB of anonymous memory, hands that buffer back to the kernel when it"
echo "[setup] receives SIGUSR1, and meanwhile writes a heartbeat file (a per-run random"
echo "[setup] nonce, its pid and a counter that grows once a second) under /data..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BUF_BYTES (48UL << 20)

static unsigned char *volatile buf = NULL;

/* SIGUSR1: hand the big buffer back to the kernel right away. */
static void on_usr1(int sig) {
    unsigned char *b = buf;
    (void)sig;
    if (b) {
        buf = NULL;
        munmap(b, BUF_BYTES);
    }
}

static void on_term(int sig) {
    (void)sig;
    _exit(0);
}

static void write_status(const char *nonce, unsigned long counter) {
    char line[256];
    int n = snprintf(line, sizeof line,
                     "nonce=%s\npid=%d\ncounter=%lu\nbuffer_mib=%d\n",
                     nonce, (int)getpid(), counter, buf ? 48 : 0);
    int fd = open("/data/status.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        if (write(fd, line, n) < 0) { /* ignore */ }
        close(fd);
        rename("/data/status.tmp", "/data/status");
    }
}

int main(void) {
    struct sigaction sa;
    char nonce[17] = "0000000000000000";
    unsigned long counter = 0;

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_usr1;
    sigaction(SIGUSR1, &sa, NULL);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);

    int rfd = open("/dev/urandom", O_RDONLY);
    if (rfd >= 0) {
        unsigned char r[8];
        if (read(rfd, r, sizeof r) == (ssize_t)sizeof r) {
            for (int i = 0; i < 8; i++) snprintf(nonce + 2 * i, 3, "%02x", r[i]);
        }
        close(rfd);
    }

    buf = mmap(NULL, BUF_BYTES, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) { buf = NULL; return 1; }
    memset(buf, 0xA5, BUF_BYTES);

    for (;;) {
        write_status(nonce, counter++);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
gcc -static -Os -s -o "$STATE_DIR/bench-app" "$STATE_DIR/app.c"

echo "[setup] packing it as an image (one layer holding /app) in 'docker save' layout..."
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
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench74849789"}],
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
python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/app.tar" "$STATE_DIR/bench-app" "$IMAGE_TAG" "$IMG_ARCH" >/dev/null
chmod 0644 "$STATE_DIR/app.tar"

echo "[setup] importing the image into containerd's 'k8s.io' namespace, where the CRI"
echo "[setup] looks for images (there is no registry to pull this private image from)..."
sudo ctr -n k8s.io images import "$STATE_DIR/app.tar" >/dev/null
rm -f "$STATE_DIR/app.tar" "$STATE_DIR/mkimage.py" "$STATE_DIR/app.c" "$STATE_DIR/bench-app"

echo "[setup] writing the pod and container configs. The container is created with a"
echo "[setup] 128 MiB memory limit, and the host dir $DATA_DIR is mounted at /data..."
python3 - "$WORK_DIR" "$IMAGE_TAG" "$POD_NAME" "$CONTAINER_NAME" "$DATA_DIR" "$INITIAL_LIMIT" <<'PYEOF'
import json
import sys

work, image, pod, name, data, limit = sys.argv[1:7]
with open(work + "/pod.json", "w") as f:
    json.dump({
        "metadata": {"name": pod, "namespace": "default", "attempt": 1,
                     "uid": "bench74849789-uid"},
        "log_directory": work + "/logs",
        "linux": {},
    }, f)
with open(work + "/container.json", "w") as f:
    json.dump({
        "metadata": {"name": name},
        "image": {"image": image},
        "log_path": name + ".log",
        "mounts": [{"container_path": "/data", "host_path": data, "readonly": False}],
        "linux": {"resources": {"memory_limit_in_bytes": int(limit)}},
    }, f)
PYEOF

echo "[setup] starting the pod sandbox and the workload container..."
POD_ID=$($CRICTL runp "$WORK_DIR/pod.json" 2>/dev/null)
CONTAINER_ID=$($CRICTL create "$POD_ID" "$WORK_DIR/container.json" "$WORK_DIR/pod.json" 2>/dev/null)
$CRICTL start "$CONTAINER_ID" >/dev/null
echo "  -> pod $POD_ID"
echo "  -> container $CONTAINER_ID"

echo "[setup] waiting until the workload has filled its buffer (heartbeat file says"
echo "[setup] buffer_mib=48)..."
READY=""
for _ in $(seq 1 40); do
    if grep -qx "buffer_mib=48" "$DATA_DIR/status" 2>/dev/null; then READY=1; break; fi
    sleep 0.5
done
[ -n "$READY" ] || { echo "[setup] ERROR: the workload never reported its 48 MiB buffer"; exit 1; }

echo "[setup] recording the workload's identity (container id, host pid and its start"
echo "[setup] time, the heartbeat nonce) so the checks can tell it is the same one..."
PID=$($CRICTL inspect -o go-template --template '{{.info.pid}}' "$CONTAINER_ID")
STARTTIME=$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}')
NONCE=$(sed -n 's/^nonce=//p' "$DATA_DIR/status")
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "$CONTAINER_ID" > "$STATE_DIR/container_id"
echo "$PID" > "$STATE_DIR/pid"
echo "$STARTTIME" > "$STATE_DIR/starttime"
echo "$NONCE" > "$STATE_DIR/nonce"
echo "  -> host pid $PID, nonce $NONCE"

echo "[setup] done. The workload is running in container $CONTAINER_NAME with a"
echo "[setup] memory limit of $INITIAL_LIMIT bytes and about 48 MiB of it in use."
