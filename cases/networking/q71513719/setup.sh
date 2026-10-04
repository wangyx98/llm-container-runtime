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
CASE_ID="bench71513719"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CONTAINER_NAME="$CASE_ID"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
PORT=8085

echo "[setup] checking containerd and its ctr client are installed (the runtime under test)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v curl >/dev/null || { echo "[setup] ERROR: curl not found"; exit 1; }
command -v nsenter >/dev/null || { echo "[setup] ERROR: nsenter (util-linux) not found"; exit 1; }
containerd --version

echo "[setup] ensuring nerdctl is installed (the task allows it next to ctr)..."
# BENCH_NO_NERDCTL=1 skips this. It exists only for a test machine that has no network
# access and no nerdctl; the oracle never uses nerdctl, but solutions that do will fail there.
if [ "${BENCH_NO_NERDCTL:-0}" = "1" ]; then
    echo "[setup] BENCH_NO_NERDCTL=1: not installing nerdctl"
elif ! command -v nerdctl >/dev/null 2>&1; then
    case "$(uname -m)" in
        x86_64) NA="amd64" ;;
        aarch64|arm64) NA="arm64" ;;
        *) echo "[setup] unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
    TAG=$(curl -fsSL https://api.github.com/repos/containerd/nerdctl/releases/latest \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")
    VER="${TAG#v}"
    echo "[setup] downloading nerdctl $TAG for linux-$NA ..."
    curl -fsSL -o /tmp/nerdctl.tar.gz \
        "https://github.com/containerd/nerdctl/releases/download/${TAG}/nerdctl-${VER}-linux-${NA}.tar.gz"
    sudo tar Cxzf /usr/local/bin /tmp/nerdctl.tar.gz nerdctl
fi

echo "[setup] ensuring CNI plugins (bridge/portmap/etc) are installed in /opt/cni/bin..."
if [ ! -x /opt/cni/bin/bridge ] || [ ! -x /opt/cni/bin/portmap ]; then
    case "$(uname -m)" in
        x86_64) CA="amd64" ;;
        aarch64|arm64) CA="arm64" ;;
        *) echo "[setup] unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
    CNI_TAG=$(curl -fsSL https://api.github.com/repos/containernetworking/plugins/releases/latest \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")
    echo "[setup] downloading CNI plugins $CNI_TAG for linux-$CA ..."
    curl -fsSL -o /tmp/cni-plugins.tgz \
        "https://github.com/containernetworking/plugins/releases/download/${CNI_TAG}/cni-plugins-linux-${CA}-${CNI_TAG}.tgz"
    sudo mkdir -p /opt/cni/bin
    sudo tar Cxzf /opt/cni/bin /tmp/cni-plugins.tgz
fi

echo "[setup] ensuring gcc is available (only to compile the small fixed web server that is"
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

echo "[setup] making sure host port $PORT is free: nothing listens on it and no NAT rule"
echo "[setup] mentions it (this case owns that port while it runs)..."
if python3 - "$PORT" <<'PYEOF'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    sys.exit(1)
PYEOF
then
    echo "  -> nothing listens on $PORT"
else
    echo "[setup] ERROR: something on this machine already listens on port $PORT; stop it and run again"
    exit 1
fi
if sudo iptables -t nat -S 2>/dev/null | grep -qE -- "--dports? ([0-9,:]*[,:])?$PORT( |,|$)"; then
    echo "[setup] ERROR: a NAT rule for port $PORT already exists on this machine; remove it and run again"
    exit 1
fi

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

TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
echo "$TOKEN" > "$STATE_DIR/token"

# a solution may switch these on (forwarding and DNAT to 127.0.0.1 need them); cleanup.sh puts
# them back to what they are now
cat /proc/sys/net/ipv4/ip_forward > "$STATE_DIR/orig_ip_forward"
cat /proc/sys/net/ipv4/conf/all/route_localnet > "$STATE_DIR/orig_route_localnet"

echo "[setup] compiling the web server. It listens on TCP port $PORT and answers every request"
echo "[setup] with three lines: a per-run token, the pid namespace it runs in, and its pid..."
cat > "$STATE_DIR/webd.c" <<'CEOF'
#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    int s = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons(PORT);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 32) < 0)
        return 1;
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0)
            continue;
        struct timeval tv = {2, 0};          /* a client that never sends must not block the rest */
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        char req[2048];
        (void)read(c, req, sizeof req);
        char ns[128] = "unknown";
        ssize_t n = readlink("/proc/self/ns/pid", ns, sizeof ns - 1);
        ns[n > 0 ? n : 0] = 0;
        if (n <= 0)
            strcpy(ns, "unknown");
        char body[512], head[256];
        int bl = snprintf(body, sizeof body, "token=" TOKEN "\npidns=%s\npid=%d\n", ns, (int)getpid());
        int hl = snprintf(head, sizeof head,
                          "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n"
                          "Connection: close\r\n\r\n", bl);
        (void)write(c, head, hl);
        (void)write(c, body, bl);
        close(c);
    }
}
CEOF
gcc -static -Os -s -w -DPORT="$PORT" -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/webd" "$STATE_DIR/webd.c"

echo "[setup] writing the image in 'docker save' layout (manifest.json + config blob + one"
echo "[setup] layer holding /usr/bin/webd, which is the image's default command)..."
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
    ti = tarfile.TarInfo("usr/bin/webd")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": arch,
    "os": "linux",
    "created": "1970-01-01T00:00:00Z",
    "config": {"Cmd": ["/usr/bin/webd"], "ExposedPorts": {"8085/tcp": {}}},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench71513719"}],
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
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/app.tar" "$STATE_DIR/webd" "$IMAGE_REF" "$IMG_ARCH")
chmod 0644 "$STATE_DIR/app.tar"
echo "$IMAGE_ID" > "$STATE_DIR/image_id"

echo "[setup] importing it into containerd's 'default' namespace (there is no registry to"
echo "[setup] pull this private image from)..."
sudo ctr images import "$STATE_DIR/app.tar" >/dev/null
rm -f "$STATE_DIR/app.tar" "$STATE_DIR/mkimage.py" "$STATE_DIR/webd.c" "$STATE_DIR/webd"
sudo ctr images ls -q | grep -qFx "$IMAGE_REF" || { echo "[setup] ERROR: containerd does not list $IMAGE_REF"; exit 1; }
echo "  -> $IMAGE_REF"

echo "[setup] starting the engineer's container the way they did: plain ctr run, no network"
echo "[setup] options (ctr has no -p)..."
timeout -k 5 60 sudo ctr run -d "$IMAGE_REF" "$CONTAINER_NAME" </dev/null

echo "[setup] waiting until it runs and its server answers inside the container's own network..."
PID=""
UP=0
for _ in $(seq 1 40); do
    PID=$(sudo ctr tasks ls 2>/dev/null | awk -v n="$CONTAINER_NAME" '$1==n && $3=="RUNNING" {print $2}')
    if [ -n "$PID" ] && sudo nsenter -t "$PID" -n curl -fsS --noproxy '*' --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null | grep -qFx "token=$TOKEN"; then
        UP=1
        break
    fi
    sleep 0.5
done
[ "$UP" = "1" ] || { echo "[setup] ERROR: the container did not start or its server does not answer"; exit 1; }
echo "$PID" > "$STATE_DIR/pid"
echo "  -> host pid $PID"

echo "[setup] done. Container $CONTAINER_NAME runs; its server listens on port $PORT inside the"
echo "[setup] container's own network namespace, and the host cannot reach it."
