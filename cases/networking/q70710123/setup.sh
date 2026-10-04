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
CASE_ID="bench70710123"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
PORT=7070

echo "[setup] checking containerd and its ctr client are installed (the runtime under test)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v curl >/dev/null || { echo "[setup] ERROR: curl not found"; exit 1; }
command -v nsenter >/dev/null || { echo "[setup] ERROR: nsenter (util-linux) not found"; exit 1; }
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }
containerd --version

echo "[setup] ensuring nerdctl is installed (the tool this task is about)..."
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

echo "[setup] making sure host port $PORT is free: this case owns that port while it runs..."
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

# a solution might edit the host's /etc/hosts (the name is meant for the container, not the
# host); cleanup.sh puts the file back to what it is now
cp /etc/hosts "$STATE_DIR/etc_hosts.orig"

echo "[setup] compiling the application. '/usr/bin/probe app' requests"
echo "[setup] http://host.docker.internal:$PORT/ every 2 seconds; '/usr/bin/probe fetch URL' does"
echo "[setup] one request (the oracle uses it)..."
cat > "$STATE_DIR/probe.c" <<'CEOF'
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define APP_URL "http://host.docker.internal:" PORTSTR "/"

/* name -> IPv4: a literal address, then /etc/hosts (read here, so that a static binary does
   not depend on NSS libraries that the image does not have), then the resolver */
static int resolve(const char *name, struct in_addr *out) {
    if (inet_pton(AF_INET, name, out) == 1)
        return 0;
    FILE *f = fopen("/etc/hosts", "r");
    if (f) {
        char line[512];
        while (fgets(line, sizeof line, f)) {
            char *hash = strchr(line, '#');
            if (hash)
                *hash = 0;
            char *save = NULL;
            char *ip = strtok_r(line, " \t\r\n", &save);
            struct in_addr a;
            if (!ip || inet_pton(AF_INET, ip, &a) != 1)
                continue;
            char *n;
            while ((n = strtok_r(NULL, " \t\r\n", &save)))
                if (strcmp(n, name) == 0) {
                    fclose(f);
                    *out = a;
                    return 0;
                }
        }
        fclose(f);
    }
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(name, NULL, &hints, &res) == 0 && res) {
        *out = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
        freeaddrinfo(res);
        return 0;
    }
    return -1;
}

/* exit codes: 0 = HTTP 200 (body on stdout), 2 = bad usage, 3 = name does not resolve,
   4 = cannot connect, 5 = answer is not HTTP 200 */
static int fetch(const char *url) {
    char host[256], path[256] = "/";
    int port = 80;
    if (strncmp(url, "http://", 7) != 0) {
        fprintf(stderr, "probe: only http:// URLs are supported\n");
        return 2;
    }
    const char *p = url + 7;
    size_t hl = strcspn(p, ":/");
    if (hl == 0 || hl >= sizeof host) {
        fprintf(stderr, "probe: bad URL\n");
        return 2;
    }
    memcpy(host, p, hl);
    host[hl] = 0;
    p += hl;
    if (*p == ':') {
        port = atoi(p + 1);
        p += 1 + strspn(p + 1, "0123456789");
    }
    if (*p == '/')
        snprintf(path, sizeof path, "%s", p);

    struct in_addr ia;
    if (resolve(host, &ia) < 0) {
        fprintf(stderr, "probe: cannot resolve '%s'\n", host);
        return 3;
    }
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct timeval tv = {3, 0};
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr = ia;
    if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) {
        fprintf(stderr, "probe: cannot connect to %s (%s) port %d: %s\n", host, inet_ntoa(ia), port,
                strerror(errno));
        close(s);
        return 4;
    }
    char req[512];
    int rl = snprintf(req, sizeof req, "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n", path, host);
    (void)write(s, req, rl);
    char buf[4096];
    size_t n = 0;
    ssize_t r;
    while (n < sizeof buf - 1 && (r = read(s, buf + n, sizeof buf - 1 - n)) > 0)
        n += (size_t)r;
    buf[n] = 0;
    close(s);
    if (n < 12 || strncmp(buf, "HTTP/1.", 7) != 0 || strncmp(buf + 9, "200", 3) != 0) {
        fprintf(stderr, "probe: unexpected answer from %s: %.40s\n", host, n ? buf : "(nothing)");
        return 5;
    }
    char *body = strstr(buf, "\r\n\r\n");
    fputs(body ? body + 4 : "", stdout);
    return 0;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    if (argc == 3 && strcmp(argv[1], "fetch") == 0)
        return fetch(argv[2]);
    if (argc == 2 && strcmp(argv[1], "app") == 0) {
        setvbuf(stdout, NULL, _IOLBF, 0);
        for (;;) {
            printf("probe: GET %s\n", APP_URL);
            fflush(stdout);
            int rc = fetch(APP_URL);
            printf(rc == 0 ? "probe: the host service answered\n" : "probe: request failed (%d)\n", rc);
            fflush(stdout);
            sleep(2);
        }
    }
    fprintf(stderr, "usage: probe app | probe fetch URL\n");
    return 2;
}
CEOF
# (the linker warns that a static program calls getaddrinfo; the program reads /etc/hosts itself
# first, so the warning is irrelevant here and only shown if the compilation fails)
gcc -static -Os -s -w -DPORTSTR="\"$PORT\"" -o "$STATE_DIR/probe" "$STATE_DIR/probe.c" 2>"$STATE_DIR/gcc.log" \
    || { cat "$STATE_DIR/gcc.log"; echo "[setup] ERROR: compiling the application failed"; exit 1; }

echo "[setup] writing the image in 'docker save' layout (manifest.json + config blob + one"
echo "[setup] layer holding /usr/bin/probe, which is the image's default command)..."
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
    for d in ("etc", "usr", "usr/bin"):
        ti = tarfile.TarInfo(d)
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 0
        lt.addfile(ti)
    ti = tarfile.TarInfo("usr/bin/probe")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": arch,
    "os": "linux",
    "created": "1970-01-01T00:00:00Z",
    "config": {"Cmd": ["/usr/bin/probe", "app"]},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench70710123"}],
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
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/app.tar" "$STATE_DIR/probe" "$IMAGE_REF" "$IMG_ARCH")
chmod 0644 "$STATE_DIR/app.tar"
echo "$IMAGE_ID" > "$STATE_DIR/image_id"

echo "[setup] importing it into containerd's 'default' namespace (there is no registry to"
echo "[setup] pull this private image from)..."
sudo ctr images import "$STATE_DIR/app.tar" >/dev/null
rm -f "$STATE_DIR/app.tar" "$STATE_DIR/mkimage.py" "$STATE_DIR/probe.c" "$STATE_DIR/probe"
sudo ctr images ls -q | grep -qFx "$IMAGE_REF" || { echo "[setup] ERROR: containerd does not list $IMAGE_REF"; exit 1; }
echo "  -> $IMAGE_REF"

echo "[setup] starting the host's test service on 0.0.0.0:$PORT (a plain host process; it answers every"
echo "[setup] GET with a per-run token and the address the request came from)..."
cat > "$STATE_DIR/hostsvc.py" <<'PYEOF'
import http.server
import os
import sys

TOKEN, PORT = sys.argv[1], int(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("token=%s\nserver=host-test-service\npid=%d\npeer=%s\n"
                % (TOKEN, os.getpid(), self.client_address[0])).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF
setsid nohup python3 "$STATE_DIR/hostsvc.py" "$TOKEN" "$PORT" >/dev/null 2>&1 </dev/null &
echo $! > "$STATE_DIR/hostsvc.pid"
UP=0
for _ in $(seq 1 40); do
    if curl -fsS --noproxy '*' --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null | grep -qFx "token=$TOKEN"; then
        UP=1
        break
    fi
    sleep 0.25
done
[ "$UP" = "1" ] || { echo "[setup] ERROR: the host test service does not answer on port $PORT"; exit 1; }
echo "  -> host pid $(cat "$STATE_DIR/hostsvc.pid")"

echo "[setup] done. The image is imported, no container exists, and the host's test service"
echo "[setup] listens on port $PORT."
