#!/bin/bash
set -e

# Ubuntu 22.04/24.04 ship `needrestart`: keep apt non-interactive (same workaround as the other cases).
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CASE_ID="bench59811664"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"           # root-only: token, ids, registry data + log, config backups
WS_DIR="$WORK_DIR/workstation"         # root-only: the build machine's own podman store
WS_PODMAN="sudo podman --root $WS_DIR/root --runroot $WS_DIR/run"
WS_IMAGE="localhost/$CASE_ID/app:v1"
REG_PORT=5000

# --- CRI-O + crictl environment: identical to the one q65650082 uses (same
# --- pinned versions, same cgroupfs / CNI / systemd-networkd workarounds),
# --- so both CRI-O cases run on the same, already-proven base.
# Pin CRI-O to the v1.34 stable stream and crictl to the matching v1.34.0
# release (crictl's own compatibility guidance: its minor version should
# match, or be at most one minor newer than, the CRI runtime's). v1.34 is
# the oldest stream still marked "Stable" (not end-of-life) on
# https://github.com/cri-o/packaging as of 2026-09, i.e. deliberately NOT
# the newest v1.38 stream -- a recent, actively-changing "latest" runtime
# package broke an earlier case in this benchmark with an upstream
# regression, so a slightly older, more battle-tested stable version is
# used here instead.
CRIO_VERSION="v1.34"
CRICTL_VERSION="v1.34.0"

# crictl's GitHub release ships separate per-arch tarballs (linux-amd64,
# linux-arm64, ...); unlike the apt-installed cri-o package (which apt
# resolves to the host's native arch automatically), this raw binary
# download must pick the right one explicitly -- an ARM64 host (e.g. a
# Multipass VM on Apple Silicon) given the amd64 tarball gets a binary
# that fails with "Exec format error" the moment it's run.
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    armv7l|armhf)   CRICTL_ARCH="arm" ;;
    ppc64le)        CRICTL_ARCH="ppc64le" ;;
    s390x)          CRICTL_ARCH="s390x" ;;
    *)
        echo "[setup] WARNING: unrecognized architecture '$(uname -m)', defaulting to amd64" >&2
        CRICTL_ARCH="amd64"
        ;;
esac

echo "[setup] ensuring CRI-O is installed AT the pinned $CRIO_VERSION stream..."
echo "[setup] (not just 'installed at all' -- a host that already has a"
echo "[setup]  different crio version from an earlier experiment must be"
echo "[setup]  corrected to the pinned version, not left as-is)"
PINNED_CRIO_MINOR="${CRIO_VERSION#v}"
CURRENT_CRIO_VERSION=""
if command -v crio >/dev/null 2>&1; then
    CURRENT_CRIO_VERSION=$(crio --version 2>/dev/null | head -1 | awk '{print $3}')
fi
if [[ "$CURRENT_CRIO_VERSION" != "${PINNED_CRIO_MINOR}."* ]]; then
    echo "[setup] crio is '${CURRENT_CRIO_VERSION:-not installed}', pinned stream is $CRIO_VERSION -- (re)installing..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl gnupg ca-certificates

    # a stale apt source pinned to a DIFFERENT cri-o stream (e.g. left over
    # from an earlier manual install) would otherwise win version
    # resolution over the one we're about to add below.
    for f in /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        if grep -q "isv:/cri-o:/stable:/" "$f" 2>/dev/null; then
            echo "[setup]   removing pre-existing CRI-O apt source: $f"
            sudo rm -f "$f"
        fi
    done

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
        | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/cri-o.list > /dev/null

    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" --allow-downgrades --allow-change-held-packages cri-o
else
    echo "[setup] crio $CURRENT_CRIO_VERSION already matches the pinned $CRIO_VERSION stream, skipping install."
fi

echo "[setup] confirming crio binary is on PATH..."
command -v crio
crio --version | head -1

echo "[setup] ensuring crictl is installed AT the pinned $CRICTL_VERSION (matching CRI-O's minor)..."
CURRENT_CRICTL_VERSION=""
if command -v crictl >/dev/null 2>&1; then
    CURRENT_CRICTL_VERSION=$(crictl --version 2>/dev/null | awk '{print $3}')
fi
if [ "$CURRENT_CRICTL_VERSION" != "$CRICTL_VERSION" ]; then
    echo "[setup] crictl is '${CURRENT_CRICTL_VERSION:-not installed}', pinned version is $CRICTL_VERSION -- (re)installing..."
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
else
    echo "[setup] crictl $CURRENT_CRICTL_VERSION already matches the pinned $CRICTL_VERSION, skipping install."
fi
command -v crictl
crictl --version

echo "[setup] pointing crictl explicitly at the CRI-O socket..."
cat <<EOF | sudo tee /etc/crictl.yaml > /dev/null
runtime-endpoint: unix:///var/run/crio/crio.sock
image-endpoint: unix:///var/run/crio/crio.sock
timeout: 10
debug: false
EOF

echo "[setup] forcing the cgroupfs cgroup manager..."
echo "[setup] (sidesteps the systemd-driver requirement that cgroup_parent be"
echo "[setup]  set to a valid slice name in pod-config.json -- the minimal"
echo "[setup]  pod-config used by this case, matching crictl's own docs"
echo "[setup]  example, leaves cgroup_parent unset)"
sudo mkdir -p /etc/crio/crio.conf.d
cat <<EOF | sudo tee /etc/crio/crio.conf.d/01-cgroup-manager.conf > /dev/null
[crio.runtime]
cgroup_manager = "cgroupfs"
EOF

echo "[setup] enabling the default CNI bridge plugin (ships disabled)..."
if [ -f /etc/cni/net.d/10-crio-bridge.conflist.disabled ]; then
    sudo mv /etc/cni/net.d/10-crio-bridge.conflist.disabled /etc/cni/net.d/10-crio-bridge.conflist
fi

echo "[setup] working around a systemd-networkd vs CNI bridge-plugin MAC"
echo "[setup] conflict: systemd's default MACAddressPolicy=persistent for"
echo "[setup] virtual NICs reassigns a freshly-created veth's MAC right after"
echo "[setup] the CNI bridge plugin sets it, before CRI-O reads it back --"
echo "[setup] this causes a deterministic 'Interface vethXXX Mac doesn't"
echo "[setup] match ... not found' failure on EVERY RunPodSandbox call, on"
echo "[setup] any host where systemd-networkd (not NetworkManager) manages"
echo "[setup] networking. Only applies when systemd-networkd is active."
if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    if [ ! -f /etc/systemd/network/98-cni-veth.link ]; then
        echo "[setup] systemd-networkd is active -- installing a udev .link rule so"
        echo "[setup] CNI-created veth* interfaces keep the MAC CNI assigned them..."
        cat <<'EOF' | sudo tee /etc/systemd/network/98-cni-veth.link > /dev/null
[Match]
OriginalName=veth*

[Link]
MACAddressPolicy=none
EOF
        sudo udevadm control --reload
    else
        echo "[setup] .link rule already present, skipping."
    fi
else
    echo "[setup] systemd-networkd is not the active network manager, skipping"
    echo "[setup] (this workaround is specific to that manager)."
fi

echo "[setup] (re)starting crio.service so the config above takes effect..."
sudo systemctl enable crio.service >/dev/null 2>&1 || true
sudo systemctl restart crio.service
sleep 2
sudo systemctl is-active crio.service

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] ensuring podman and gcc are installed (podman = the build machine's tool, gcc only"
echo "[setup] compiles the small fixed program that goes into the image)..."
if ! command -v podman >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" podman
fi
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v podman python3 gcc >/dev/null
sudo podman info >/dev/null

echo "[setup] making sure CRI-O already has its pause image, so starting a pod later does not"
echo "[setup] depend on a registry round trip..."
PAUSE_IMAGE=$(sudo crio config 2>/dev/null | awk -F'"' '/^[[:space:]]*pause_image[[:space:]]*=/ {print $2; exit}')
if [ -n "$PAUSE_IMAGE" ]; then
    sudo crictl pull "$PAUSE_IMAGE" >/dev/null 2>&1 \
        || echo "[setup] note: could not pull $PAUSE_IMAGE now (it may already be cached)"
fi

echo "[setup] finding this host's address on its default route (the registry listens there; a"
echo "[setup] loopback address would hide the problem: CRI-O falls back to plain HTTP for 127.0.0.0/8)..."
REG_IP=$(python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("192.0.2.1", 9)); print(s.getsockname()[0])
except OSError:
    pass')
case "$REG_IP" in
    ""|127.*) echo "[setup] NOT APPLICABLE: no non-loopback IPv4 address on a default route (got '${REG_IP}')"; exit 1 ;;
esac
if python3 -c 'import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex((sys.argv[1], int(sys.argv[2]))) == 0 else 1)' "$REG_IP" "$REG_PORT"; then
    echo "[setup] ERROR: $REG_IP:$REG_PORT is already in use"; exit 1
fi
REGISTRY="$REG_IP:$REG_PORT"
echo "  -> registry address $REGISTRY"

echo "[setup] resetting the work dir (the work dir is writable for the user; $STATE_DIR and"
echo "[setup] $WS_DIR are root-only)..."
sudo rm -rf "$WORK_DIR"
install -d -m 0755 "$WORK_DIR"
sudo install -d -m 0700 "$STATE_DIR" "$STATE_DIR/registry" "$WS_DIR"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "[setup] backing up the registry configuration files CRI-O reads (cleanup restores them)..."
sudo install -d -m 0700 "$STATE_DIR/containers-conf"
if [ -f /etc/containers/registries.conf ]; then
    sudo cp -p /etc/containers/registries.conf "$STATE_DIR/containers-conf/registries.conf"
fi
sudo ls /etc/containers/registries.conf.d 2>/dev/null | sudo tee "$STATE_DIR/containers-conf/conf.d.list" >/dev/null || true

echo "[setup] building the image on the 'build machine': its own podman store ($WS_DIR),"
echo "[setup] separate from the default root store that CRI-O shares. The program prints the content"
echo "[setup] of /etc/unique.txt, a file with a per-run random token that exists only in this image..."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
mkdir -p "$BUILD/ctx"
cat > "$BUILD/app.c" <<'CEOF'
#include <stdio.h>
#include <time.h>
int main(void) {
    char b[128] = "?";
    FILE *f = fopen("/etc/unique.txt", "r");
    if (f) { if (!fgets(b, sizeof b, f)) b[0] = 0; fclose(f); }
    for (int i = 0; b[i]; i++) if (b[i] == '\n') b[i] = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        printf("bench59811664-app file=%s\n", b);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
gcc -static -Os -s -o "$BUILD/ctx/app" "$BUILD/app.c"
echo "$TOKEN" > "$BUILD/ctx/unique.txt"
cat > "$BUILD/ctx/Containerfile" <<'CEOF'
FROM scratch
COPY app /app
COPY unique.txt /etc/unique.txt
ENTRYPOINT ["/app"]
CEOF
$WS_PODMAN build -q --format oci -t "$WS_IMAGE" "$BUILD/ctx" >/dev/null
IMAGE_ID=$($WS_PODMAN image inspect --format '{{.Id}}' "$WS_IMAGE")
IMAGE_ID=${IMAGE_ID#sha256:}
echo "$IMAGE_ID" | grep -qE '^[0-9a-f]{64}$' || { echo "[setup] ERROR: no valid image id ('$IMAGE_ID')"; exit 1; }
DIFF_ID=$($WS_PODMAN image inspect --format '{{index .RootFS.Layers 0}}' "$WS_IMAGE")
echo "$TOKEN" | sudo tee "$STATE_DIR/token" >/dev/null
echo "$IMAGE_ID" | sudo tee "$STATE_DIR/expected_image_id" >/dev/null
echo "${DIFF_ID#sha256:}" | sudo tee "$STATE_DIR/diff_id" >/dev/null
echo "$REGISTRY" | sudo tee "$STATE_DIR/registry_addr" >/dev/null
echo "  -> $WS_IMAGE has image id sha256:$IMAGE_ID (the build context is gone: it was in a temp dir)"

echo "[setup] starting the registry: a small plain-HTTP registry (API v2) that stands in for the one"
echo "[setup] of Minikube's registry addon: it listens on $REGISTRY, is empty, and writes one"
echo "[setup] log line per request (time, method, path, status, User-Agent) to $STATE_DIR/registry.log..."
sudo tee "$STATE_DIR/registry.py" >/dev/null <<'PYEOF'
import hashlib, http.server, json, os, sys, threading, time, uuid

ADDR, PORT, ROOT, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
for d in ("blobs", "manifests", "uploads"):
    os.makedirs(ROOT + "/" + d, exist_ok=True)
lock = threading.Lock()


def log(h, code):
    with lock, open(LOG, "a") as f:
        f.write("%d %s %s %d %s\n" % (time.time_ns(), h.command, h.path, code,
                                      h.headers.get("User-Agent", "-").replace(" ", "_")))


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, body=b"", headers=None, ctype=None):
        self.send_response(code)
        self.send_header("Docker-Distribution-API-Version", "registry/2.0")
        if ctype:
            self.send_header("Content-Type", ctype)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        log(self, code)

    def body(self):
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            out = b""
            while True:
                n = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if n == 0:
                    self.rfile.readline()
                    return out
                out += self.rfile.read(n)
                self.rfile.readline()
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def parts(self):
        p = self.path.split("?")[0]
        q = dict(x.split("=", 1) for x in self.path.split("?", 1)[1].split("&")) if "?" in self.path else {}
        return p, q

    def do_GET(self):
        self.get()

    def do_HEAD(self):
        self.get()

    def get(self):
        p, _ = self.parts()
        if p in ("/v2/", "/v2"):
            return self.send(200, b"{}", ctype="application/json")
        if "/blobs/" in p:
            dg = p.rsplit("/blobs/", 1)[1]
            fn = ROOT + "/blobs/" + dg.replace(":", "_")
            if os.path.exists(fn):
                return self.send(200, open(fn, "rb").read(), {"Docker-Content-Digest": dg}, "application/octet-stream")
            return self.send(404)
        if "/manifests/" in p:
            name, ref = p[len("/v2/"):].split("/manifests/", 1)
            fn = ROOT + "/manifests/" + name.replace("/", "_") + "__" + ref.replace(":", "_")
            if os.path.exists(fn):
                raw = open(fn, "rb").read()
                dg = "sha256:" + hashlib.sha256(raw).hexdigest()
                return self.send(200, raw, {"Docker-Content-Digest": dg},
                                 json.loads(raw).get("mediaType", "application/vnd.oci.image.manifest.v1+json"))
            return self.send(404, b'{"errors":[{"code":"MANIFEST_UNKNOWN"}]}', ctype="application/json")
        self.send(404)

    def do_POST(self):
        p, _ = self.parts()
        if p.endswith("/blobs/uploads/"):
            u = uuid.uuid4().hex
            open(ROOT + "/uploads/" + u, "wb").close()
            return self.send(202, b"", {"Location": p + u, "Docker-Upload-UUID": u, "Range": "0-0"})
        self.send(404)

    def do_PATCH(self):
        p, _ = self.parts()
        u = p.rsplit("/", 1)[1]
        with open(ROOT + "/uploads/" + u, "ab") as f:
            f.write(self.body())
        size = os.path.getsize(ROOT + "/uploads/" + u)
        self.send(202, b"", {"Location": p, "Docker-Upload-UUID": u, "Range": "0-%d" % max(size - 1, 0)})

    def do_PUT(self):
        p, q = self.parts()
        if "/blobs/uploads/" in p:
            u = p.rsplit("/", 1)[1]
            with open(ROOT + "/uploads/" + u, "ab") as f:
                f.write(self.body())
            blob = open(ROOT + "/uploads/" + u, "rb").read()
            dg = q.get("digest", "").replace("%3A", ":")
            if "sha256:" + hashlib.sha256(blob).hexdigest() != dg:
                return self.send(400, b'{"errors":[{"code":"DIGEST_INVALID"}]}', ctype="application/json")
            open(ROOT + "/blobs/" + dg.replace(":", "_"), "wb").write(blob)
            os.remove(ROOT + "/uploads/" + u)
            return self.send(201, b"", {"Location": "/v2/blobs/" + dg, "Docker-Content-Digest": dg})
        if "/manifests/" in p:
            name, ref = p[len("/v2/"):].split("/manifests/", 1)
            raw = self.body()
            dg = "sha256:" + hashlib.sha256(raw).hexdigest()
            for r in (ref, dg):
                open(ROOT + "/manifests/" + name.replace("/", "_") + "__" + r.replace(":", "_"), "wb").write(raw)
            return self.send(201, b"", {"Docker-Content-Digest": dg, "Location": p})
        self.send(404)


http.server.ThreadingHTTPServer((ADDR, PORT), H).serve_forever()
PYEOF
sudo sh -c ": > '$STATE_DIR/registry.log'"
sudo sh -c "setsid nohup python3 '$STATE_DIR/registry.py' '$REG_IP' '$REG_PORT' '$STATE_DIR/registry/data' '$STATE_DIR/registry.log' >/dev/null 2>&1 </dev/null & echo \$! > '$STATE_DIR/registry.pid'"
for _ in $(seq 1 30); do
    python3 -c 'import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex((sys.argv[1], int(sys.argv[2]))) == 0 else 1)' "$REG_IP" "$REG_PORT" && break
    sleep 0.3
done
python3 -c 'import sys,urllib.request; urllib.request.urlopen("http://" + sys.argv[1] + "/v2/", timeout=5).read()' "$REGISTRY" \
    || { echo "[setup] ERROR: the registry does not answer"; exit 1; }
sudo sh -c ": > '$STATE_DIR/registry.log'"

echo "$REGISTRY" > "$WORK_DIR/registry.addr"

echo "[setup] done. The image exists only in the build machine's store ($WS_DIR); CRI-O does not"
echo "[setup] know it; the registry $REGISTRY is empty, plain HTTP, and CRI-O has no setting for it."
