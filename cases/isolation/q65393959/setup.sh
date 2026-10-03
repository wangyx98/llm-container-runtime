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

CASE_ID="bench65393959"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
POD_NAME="$CASE_ID-pod"
CONTAINER_NAME="$CASE_ID-app"
IMAGE_REF="docker.io/library/$CASE_ID-app:latest"
OWNER_NAME="$CASE_ID-owner"

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

echo "[setup] ensuring gcc is available (only to compile the small fixed program that is"
echo "[setup] every executable of the image)..."
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

# The owner of the data gets a random uid and gid on every run, so they cannot be
# written into a solution ahead of time; the container's /etc/passwd and
# /etc/group (image layer) and the host owner of the data dir carry them.
OWNER_UID=$((5000 + RANDOM % 1000))
OWNER_GID=$((6000 + RANDOM % 1000))
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
echo "$OWNER_UID" > "$STATE_DIR/uid"
echo "$OWNER_GID" > "$STATE_DIR/gid"
echo "$OWNER_NAME" > "$STATE_DIR/name"
echo "$TOKEN" > "$STATE_DIR/token"

echo "[setup] compiling the program. Under the name 'rotate' it refuses to run unless the"
echo "[setup] user that runs it owns /data/state; if it does, it writes /data/done (its"
echo "[setup] real uid, gid, user name, pid namespace and a per-run token) and prints a"
echo "[setup] line. 'id' and 'whoami' print who is running them; any other name idles..."
cat > "$STATE_DIR/tool.c" <<'CEOF'
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void name_of(unsigned uid, char *out, size_t n) {
    FILE *f = fopen("/etc/passwd", "r");
    char line[512];
    snprintf(out, n, "?");
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        char *name = strtok(line, ":");
        strtok(NULL, ":");
        char *u = strtok(NULL, ":");
        if (name && u && (unsigned)atoi(u) == uid) {
            snprintf(out, n, "%s", name);
            break;
        }
    }
    fclose(f);
}

int main(int argc, char **argv) {
    (void)argc;
    const char *base = strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    unsigned uid = geteuid(), gid = getegid();
    char name[128];
    name_of(uid, name, sizeof name);
    char groups[256] = "";
    gid_t gl[32];
    int ng = getgroups(32, gl);
    for (int i = 0; i < ng; i++) {
        char t[16];
        snprintf(t, sizeof t, "%s%u", i ? "," : "", (unsigned)gl[i]);
        strncat(groups, t, sizeof groups - strlen(groups) - 1);
    }
    if (strcmp(base, "whoami") == 0) {
        puts(name);
        return 0;
    }
    if (strcmp(base, "id") == 0) {
        printf("uid=%u(%s) gid=%u groups=%s\n", uid, name, gid, groups);
        return 0;
    }
    if (strcmp(base, "rotate") != 0) {
        for (;;) pause();
    }

    struct stat st;
    if (stat("/data/state", &st) != 0) {
        fprintf(stderr, "rotate: /data/state: %s\n", strerror(errno));
        return 2;
    }
    if (uid != st.st_uid) {
        fprintf(stderr, "rotate: refusing to run: the data in /data belongs to uid %u, but this is uid %u (%s)\n",
                (unsigned)st.st_uid, uid, name);
        return 1;
    }
    char pidns[128] = "?";
    ssize_t k = readlink("/proc/self/ns/pid", pidns, sizeof pidns - 1);
    if (k > 0) pidns[k] = 0;
    char line[1024];
    int n = snprintf(line, sizeof line, "uid=%u\ngid=%u\nuser=%s\ngroups=%s\npidns=%s\ntoken=" TOKEN "\n",
                     uid, gid, name, groups, pidns);
    int fd = open("/data/done.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "rotate: /data/done.tmp: %s\n", strerror(errno));
        return 2;
    }
    if (write(fd, line, n) < 0) {
        close(fd);
        return 2;
    }
    close(fd);
    if (rename("/data/done.tmp", "/data/done") != 0) {
        fprintf(stderr, "rotate: rename: %s\n", strerror(errno));
        return 2;
    }
    printf("bench65393959-rotate: done as uid=%u gid=%u user=%s token=" TOKEN "\n", uid, gid, name);
    return 0;
}
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/tool" "$STATE_DIR/tool.c"

echo "[setup] writing the image in 'docker save' layout (manifest.json + config blob + one"
echo "[setup] layer). The layer holds /etc/passwd and /etc/group with several users (root,"
echo "[setup] $CASE_ID-web, $OWNER_NAME uid $OWNER_UID gid $OWNER_GID, $CASE_ID-other),"
echo "[setup] the program under four names in /usr/bin, and an empty /data..."
cat > "$STATE_DIR/mkimage.py" <<'PYEOF'
import hashlib
import io
import json
import sys
import tarfile

out, binary, tag, arch, uid, gid = sys.argv[1:7]
data = open(binary, "rb").read()

passwd = (
    "root:x:0:0:root:/root:/nonexistent\n"
    "bench65393959-web:x:4701:4702::/:/nonexistent\n"
    f"bench65393959-owner:x:{uid}:{gid}::/:/nonexistent\n"
    "bench65393959-other:x:4721:4722::/:/nonexistent\n"
).encode()
group = (
    "root:x:0:\n"
    "bench65393959-web:x:4702:\n"
    f"bench65393959-owner:x:{gid}:\n"
    "bench65393959-other:x:4722:\n"
).encode()

layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    for d in ("etc", "usr", "usr/bin", "data"):
        ti = tarfile.TarInfo(d)
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 0
        lt.addfile(ti)
    for name, payload in (("etc/passwd", passwd), ("etc/group", group)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
        lt.addfile(ti, io.BytesIO(payload))
    for name in ("idle", "rotate", "id", "whoami"):
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
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench65393959"}],
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
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/app.tar" "$STATE_DIR/tool" "$IMAGE_REF" "$IMG_ARCH" "$OWNER_UID" "$OWNER_GID")
chmod 0644 "$STATE_DIR/app.tar"
echo "$IMAGE_ID" > "$STATE_DIR/image_id"

echo "[setup] importing it into containerd's 'k8s.io' namespace, where the CRI looks for"
echo "[setup] images (there is no registry to pull this private image from)..."
sudo ctr -n k8s.io images import "$STATE_DIR/app.tar" >/dev/null
rm -f "$STATE_DIR/app.tar" "$STATE_DIR/mkimage.py" "$STATE_DIR/tool.c" "$STATE_DIR/tool"
SEEN=""
for _ in $(seq 1 40); do
    if $CRICTL inspecti "sha256:$IMAGE_ID" >/dev/null 2>&1; then SEEN=1; break; fi
    sleep 0.5
done
[ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know image sha256:$IMAGE_ID"; exit 1; }
echo "  -> $IMAGE_REF  id sha256:$IMAGE_ID"

echo "[setup] creating the data: $DATA_DIR/state, owned by $OWNER_UID:$OWNER_GID (the host side"
echo "[setup] of the container's /data)..."
echo "state" > "$DATA_DIR/state"
sudo chown "$OWNER_UID:$OWNER_GID" "$DATA_DIR" "$DATA_DIR/state"

echo "[setup] writing the pod and container configs (the container runs as root, the image's"
echo "[setup] default, with the data dir mounted at /data)..."
python3 - "$WORK_DIR" "$POD_NAME" "$CONTAINER_NAME" "$IMAGE_REF" "$DATA_DIR" <<'PYEOF'
import json
import sys

work, pod, name, image, data = sys.argv[1:6]
with open(work + "/pod.json", "w") as f:
    json.dump({
        "metadata": {"name": pod, "namespace": "default", "attempt": 1,
                     "uid": "bench65393959-uid"},
        "log_directory": work + "/logs",
        "linux": {},
    }, f, indent=2)
with open(work + "/container.json", "w") as f:
    json.dump({
        "metadata": {"name": name},
        "image": {"image": image},
        "log_path": name + ".log",
        "mounts": [{"container_path": "/data", "host_path": data, "readonly": False}],
        "linux": {},
    }, f, indent=2)
PYEOF

echo "[setup] starting the pod sandbox and the container..."
POD_ID=$($CRICTL runp "$WORK_DIR/pod.json" 2>/dev/null)
CONTAINER_ID=$($CRICTL create "$POD_ID" "$WORK_DIR/container.json" "$WORK_DIR/pod.json" 2>/dev/null)
$CRICTL start "$CONTAINER_ID" >/dev/null
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "$CONTAINER_ID" > "$STATE_DIR/container_id"
echo "  -> pod $POD_ID"
echo "  -> container $CONTAINER_ID ($CONTAINER_NAME)"

echo "[setup] waiting until the container is running; recording its init pid and the pid"
echo "[setup] namespace it lives in..."
PID=""
for _ in $(seq 1 40); do
    if [ "$($CRICTL inspect -o go-template --template '{{.status.state}}' "$CONTAINER_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ]; then
        PID=$($CRICTL inspect -o go-template --template '{{.info.pid}}' "$CONTAINER_ID" 2>/dev/null || true)
        [ -n "$PID" ] && [ "$PID" != "0" ] && break
    fi
    sleep 0.5
done
[ -n "$PID" ] && [ "$PID" != "0" ] || { echo "[setup] ERROR: the container did not start"; exit 1; }
echo "$PID" > "$STATE_DIR/pid"
sudo readlink "/proc/$PID/ns/pid" > "$STATE_DIR/pidns"
echo "  -> host pid $PID, $(cat "$STATE_DIR/pidns")"

echo "[setup] done. Container $CONTAINER_NAME runs as root in pod $POD_NAME; /data holds"
echo "[setup] 'state', owned by $OWNER_NAME (a user from the image's /etc/passwd)."
