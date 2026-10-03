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

CASE_ID="bench75757759"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
POD_NAME="$CASE_ID-pod"
CONTAINER_NAME="$CASE_ID-ping"
IMAGE_REF="docker.io/library/$CASE_ID-ping:latest"

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
echo "[setup] both the image's 'ping' and its idle process)..."
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
mkdir -p "$STATE_DIR" "$WORK_DIR/logs"
cd "$WORK_DIR"

echo "[setup] compiling the program. Started as 'ping' it sends one ICMP echo request"
echo "[setup] through a RAW socket (which needs the capability CAP_NET_RAW) to the IPv4"
echo "[setup] address in its last argument and, on a reply, prints a line with a per-run"
echo "[setup] random token. Started under any other name it just idles..."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
cat > "$STATE_DIR/tool.c" <<'CEOF'
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/ip_icmp.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static unsigned short csum(void *b, int len) {
    unsigned short *p = b;
    unsigned int s = 0;
    for (; len > 1; len -= 2) s += *p++;
    if (len == 1) s += *(unsigned char *)p;
    s = (s >> 16) + (s & 0xffff);
    s += s >> 16;
    return (unsigned short)~s;
}

int main(int argc, char **argv) {
    const char *base = strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    if (strcmp(base, "ping") != 0) {
        for (;;) pause();
    }

    if (argc < 2) {
        fprintf(stderr, "usage: ping [-c N] ADDRESS\n");
        return 2;
    }
    const char *addr = argv[argc - 1];
    struct sockaddr_in to;
    memset(&to, 0, sizeof to);
    to.sin_family = AF_INET;
    if (inet_pton(AF_INET, addr, &to.sin_addr) != 1) {
        fprintf(stderr, "ping: %s: not an IPv4 address\n", addr);
        return 2;
    }

    int s = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    if (s < 0) {
        fprintf(stderr, "ping: socket: %s\n", strerror(errno));
        return 2;
    }
    struct timeval tv = {3, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

    char pkt[64];
    memset(pkt, 0, sizeof pkt);
    struct icmphdr *h = (struct icmphdr *)pkt;
    h->type = ICMP_ECHO;
    h->un.echo.id = htons(getpid() & 0xffff);
    h->un.echo.sequence = htons(1);
    memcpy(pkt + sizeof *h, "bench75757759", 13);
    h->checksum = csum(pkt, sizeof pkt);
    if (sendto(s, pkt, sizeof pkt, 0, (struct sockaddr *)&to, sizeof to) < 0) {
        fprintf(stderr, "ping: sendto: %s\n", strerror(errno));
        return 2;
    }
    for (;;) {
        char buf[256];
        ssize_t n = recv(s, buf, sizeof buf, 0);
        if (n < 0) {
            fprintf(stderr, "ping: no reply from %s (%s)\n", addr, strerror(errno));
            return 1;
        }
        int ihl = (buf[0] & 0xf) * 4;
        if (n < ihl + (int)sizeof(struct icmphdr)) continue;
        struct icmphdr *r = (struct icmphdr *)(buf + ihl);
        if (r->type == ICMP_ECHOREPLY && r->un.echo.id == h->un.echo.id) {
            printf("bench75757759-ping: reply from %s token=" TOKEN "\n", addr);
            return 0;
        }
    }
}
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/tool" "$STATE_DIR/tool.c"

echo "[setup] writing the image in 'docker save' layout (manifest.json + config blob + one"
echo "[setup] layer). The layer holds /usr/bin/ping, carrying the file capability"
echo "[setup] cap_net_raw+ep exactly as the ping of a distribution package does, and"
echo "[setup] /usr/bin/idle, the container's main process..."
cat > "$STATE_DIR/mkimage.py" <<'PYEOF'
import hashlib
import io
import json
import struct
import sys
import tarfile

out, binary, tag, arch = sys.argv[1:5]
data = open(binary, "rb").read()

# security.capability, VFS_CAP_REVISION_2 with the effective bit set:
# permitted = CAP_NET_RAW (13), inheritable = none
CAP_NET_RAW = 13
cap = struct.pack("<IIIII", 0x02000001, 1 << CAP_NET_RAW, 0, 0, 0)

layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.PAX_FORMAT) as lt:
    for d in ("usr", "usr/bin"):
        ti = tarfile.TarInfo(d)
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 0
        lt.addfile(ti)
    ti = tarfile.TarInfo("usr/bin/ping")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 0
    ti.pax_headers = {"SCHILY.xattr.security.capability": cap.decode("latin-1")}
    lt.addfile(ti, io.BytesIO(data))
    ti = tarfile.TarInfo("usr/bin/idle")
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
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench75757759"}],
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
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/ping.tar" "$STATE_DIR/tool" "$IMAGE_REF" "$IMG_ARCH")
chmod 0644 "$STATE_DIR/ping.tar"
echo "$IMAGE_ID" > "$STATE_DIR/image_id"
echo "$TOKEN" > "$STATE_DIR/token"

echo "[setup] importing it into containerd's 'k8s.io' namespace, where the CRI looks for"
echo "[setup] images (there is no registry to pull this private image from)..."
sudo ctr -n k8s.io images import "$STATE_DIR/ping.tar" >/dev/null
rm -f "$STATE_DIR/ping.tar" "$STATE_DIR/mkimage.py" "$STATE_DIR/tool.c" "$STATE_DIR/tool"
SEEN=""
for _ in $(seq 1 40); do
    if $CRICTL inspecti "sha256:$IMAGE_ID" >/dev/null 2>&1; then SEEN=1; break; fi
    sleep 0.5
done
[ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know image sha256:$IMAGE_ID"; exit 1; }
echo "  -> $IMAGE_REF  id sha256:$IMAGE_ID"

echo "[setup] writing the pod and container configs. The container is created the way a"
echo "[setup] hardened workload is: every Linux capability dropped..."
python3 - "$WORK_DIR" "$POD_NAME" "$CONTAINER_NAME" "$IMAGE_REF" <<'PYEOF'
import json
import sys

work, pod, name, image = sys.argv[1:5]
with open(work + "/pod.json", "w") as f:
    json.dump({
        "metadata": {"name": pod, "namespace": "default", "attempt": 1,
                     "uid": "bench75757759-uid"},
        "log_directory": work + "/logs",
        "linux": {},
    }, f, indent=2)
with open(work + "/container.json", "w") as f:
    json.dump({
        "metadata": {"name": name},
        "image": {"image": image},
        "log_path": name + ".log",
        "linux": {"security_context": {"capabilities": {"drop_capabilities": ["ALL"]}}},
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

echo "[setup] waiting until the container is running and recording its init pid..."
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
echo "  -> host pid $PID"

echo "[setup] done. Container $CONTAINER_NAME runs in pod $POD_NAME with all capabilities"
echo "[setup] dropped; /usr/bin/ping inside it cannot be executed."
