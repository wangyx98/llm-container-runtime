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

CASE_ID="bench71218538"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
POD_NAME="$CASE_ID-pod"
ACTIVE_NAME="$CASE_ID-active"     # container: the running workload
JOB_NAME="$CASE_ID-job"           # container: finished, from the "stopped" image
OLD_NAME="$CASE_ID-old"           # container: stopped, from the SAME image as the workload
ACTIVE_REF="docker.io/library/$CASE_ID-active:latest"
STOPPED_REF="docker.io/library/$CASE_ID-stopped:latest"
UNUSED_REF="docker.io/library/$CASE_ID-unused:latest"

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

echo "[setup] ensuring gcc is available (only to compile the small fixed programs that"
echo "[setup] are the entrypoints of the images)..."
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

echo "[setup] compiling the programs. Each build carries its own per-run random token,"
echo "[setup] so the three images differ in content (and so in image ID):"
echo "[setup]   - the workload: writes a heartbeat file (nonce, pid, a counter that grows"
echo "[setup]     once a second) under /data and runs until it is stopped,"
echo "[setup]   - two one-line programs that print their token and exit..."
cat > "$STATE_DIR/work.c" <<'CEOF'
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void on_term(int sig) {
    (void)sig;
    _exit(0);
}

static void write_status(const char *nonce, unsigned long counter) {
    char line[256];
    int n = snprintf(line, sizeof line, "nonce=%s\npid=%d\ncounter=%lu\n",
                     nonce, (int)getpid(), counter);
    int fd = open("/data/status.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        if (write(fd, line, n) < 0) { /* ignore */ }
        close(fd);
        rename("/data/status.tmp", "/data/status");
    }
}

int main(void) {
    struct sigaction sa;
    unsigned long counter = 0;

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);

    for (;;) {
        write_status(TOKEN, counter++);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
cat > "$STATE_DIR/once.c" <<'CEOF'
#include <stdio.h>

int main(void) {
    puts("bench71218538-" NAME " token=" TOKEN);
    return 0;
}
CEOF
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
gcc -static -Os -s -DTOKEN="\"$NONCE\"" -o "$STATE_DIR/active-bin" "$STATE_DIR/work.c"
gcc -static -Os -s -DNAME='"stopped"' -DTOKEN="\"$(python3 -c 'import secrets; print(secrets.token_hex(8))')\"" \
    -o "$STATE_DIR/stopped-bin" "$STATE_DIR/once.c"
gcc -static -Os -s -DNAME='"unused"' -DTOKEN="\"$(python3 -c 'import secrets; print(secrets.token_hex(8))')\"" \
    -o "$STATE_DIR/unused-bin" "$STATE_DIR/once.c"

echo "[setup] writing a generator for images in 'docker save' layout (manifest.json +"
echo "[setup] config blob + one layer holding /app)..."
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
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench71218538"}],
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

echo "[setup] importing the three images into containerd's 'k8s.io' namespace, where the"
echo "[setup] CRI looks for images (there is no registry to pull these private images from)..."
for which in active stopped unused; do
    case "$which" in
        active)  REF="$ACTIVE_REF" ;;
        stopped) REF="$STOPPED_REF" ;;
        unused)  REF="$UNUSED_REF" ;;
    esac
    ID=$(python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/$which.tar" "$STATE_DIR/$which-bin" "$REF" "$IMG_ARCH")
    chmod 0644 "$STATE_DIR/$which.tar"
    echo "$ID" > "$STATE_DIR/image_id_$which"
    sudo ctr -n k8s.io images import "$STATE_DIR/$which.tar" >/dev/null
    rm -f "$STATE_DIR/$which.tar"
    echo "  -> $REF  id sha256:$ID"
done
rm -f "$STATE_DIR/mkimage.py" "$STATE_DIR/work.c" "$STATE_DIR/once.c" "$STATE_DIR"/*-bin

echo "[setup] waiting until the CRI lists the three images..."
for which in active stopped unused; do
    ID=$(cat "$STATE_DIR/image_id_$which")
    SEEN=""
    for _ in $(seq 1 40); do
        if $CRICTL inspecti "sha256:$ID" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know image sha256:$ID ($which)"; exit 1; }
done

echo "[setup] writing the pod and container configs..."
python3 - "$WORK_DIR" "$POD_NAME" "$DATA_DIR" "$ACTIVE_NAME" "$ACTIVE_REF" "$JOB_NAME" "$STOPPED_REF" "$OLD_NAME" <<'PYEOF'
import json
import sys

work, pod, data, active, active_ref, job, stopped_ref, old = sys.argv[1:9]
with open(work + "/pod.json", "w") as f:
    json.dump({
        "metadata": {"name": pod, "namespace": "default", "attempt": 1,
                     "uid": "bench71218538-uid"},
        "log_directory": work + "/logs",
        "linux": {},
    }, f)


def container(name, image, mounts):
    with open(work + "/" + name + ".json", "w") as f:
        json.dump({
            "metadata": {"name": name},
            "image": {"image": image},
            "log_path": name + ".log",
            "mounts": mounts,
            "linux": {},
        }, f)


# only the workload gets the host dir, so only it writes the heartbeat
container(active, active_ref, [{"container_path": "/data", "host_path": data, "readonly": False}])
container(job, stopped_ref, [])
container(old, active_ref, [])
PYEOF

echo "[setup] starting the pod sandbox and the workload container (image $ACTIVE_REF)..."
POD_ID=$($CRICTL runp "$WORK_DIR/pod.json" 2>/dev/null)
ACTIVE_ID=$($CRICTL create "$POD_ID" "$WORK_DIR/$ACTIVE_NAME.json" "$WORK_DIR/pod.json" 2>/dev/null)
$CRICTL start "$ACTIVE_ID" >/dev/null
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "$ACTIVE_ID" > "$STATE_DIR/container_active"
echo "  -> pod $POD_ID"
echo "  -> container $ACTIVE_ID ($ACTIVE_NAME)"

wait_exited() {   # $1 = container id
    for _ in $(seq 1 40); do
        [ "$($CRICTL inspect -o go-template --template '{{.status.state}}' "$1" 2>/dev/null)" = "CONTAINER_EXITED" ] && return 0
        sleep 0.5
    done
    return 1
}

echo "[setup] running a one-shot container from the 'stopped' image to completion..."
JOB_ID=$($CRICTL create "$POD_ID" "$WORK_DIR/$JOB_NAME.json" "$WORK_DIR/pod.json" 2>/dev/null)
$CRICTL start "$JOB_ID" >/dev/null
wait_exited "$JOB_ID" || { echo "[setup] ERROR: $JOB_NAME did not exit"; exit 1; }
echo "$JOB_ID" > "$STATE_DIR/container_job"
echo "  -> container $JOB_ID ($JOB_NAME) exited"

echo "[setup] starting a second container from the workload's image and stopping it again,"
echo "[setup] like the leftover of an earlier restart of the workload..."
OLD_ID=$($CRICTL create "$POD_ID" "$WORK_DIR/$OLD_NAME.json" "$WORK_DIR/pod.json" 2>/dev/null)
$CRICTL start "$OLD_ID" >/dev/null
$CRICTL stop --timeout 5 "$OLD_ID" >/dev/null
wait_exited "$OLD_ID" || { echo "[setup] ERROR: $OLD_NAME did not exit"; exit 1; }
echo "$OLD_ID" > "$STATE_DIR/container_old"
echo "  -> container $OLD_ID ($OLD_NAME) exited"

echo "[setup] waiting until the workload's heartbeat file shows its counter running..."
READY=""
for _ in $(seq 1 40); do
    if grep -q '^counter=' "$DATA_DIR/status" 2>/dev/null; then READY=1; break; fi
    sleep 0.5
done
[ -n "$READY" ] || { echo "[setup] ERROR: the workload never wrote its heartbeat"; exit 1; }

echo "[setup] recording the workload's identity (host pid, its start time, the heartbeat"
echo "[setup] nonce), so the checks can tell it is the same one..."
PID=$($CRICTL inspect -o go-template --template '{{.info.pid}}' "$ACTIVE_ID")
STARTTIME=$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}')
NONCE_REC=$(sed -n 's/^nonce=//p' "$DATA_DIR/status")
echo "$PID" > "$STATE_DIR/pid"
echo "$STARTTIME" > "$STATE_DIR/starttime"
echo "$NONCE_REC" > "$STATE_DIR/nonce"
echo "  -> host pid $PID, nonce $NONCE_REC"

echo "[setup] done. In pod $POD_NAME: $ACTIVE_NAME is running; $JOB_NAME and $OLD_NAME"
echo "[setup] are stopped. Images: $ACTIVE_REF (in use), $STOPPED_REF (only a"
echo "[setup] stopped container uses it), $UNUSED_REF (no container at all)."
