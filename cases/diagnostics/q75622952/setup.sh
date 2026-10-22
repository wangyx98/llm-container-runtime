#!/bin/bash
set -e

CASE_ID="bench75622952"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node (containerd's root, its programs, the pod's definitions, the tools) and the registry front (its program, certificates, the image data)
RUN="/run/$CASE_ID"                          # containerd's state and socket, the front's log, mode file and pid file
CACHE="/var/cache/$CASE_ID"                  # the downloaded containerd, runc and crictl (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl, crictl, ctr (with the node's socket), frontctl
NODEBIN="$LIB/node/bin"                      # first in the PATH of the node's containerd: containerd, its shim and runc are found here
ETC="$LIB/etc"                               # containerd.toml: THE file of the task
PKI="$LIB/pki"
FRONT="$LIB/front"
PODS="$LIB/pods"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
ADDR="10.75.62.29"                           # the registry's address: a /32 alias of lo (not 127.x: containerd pulls from loopback registries over plain HTTP by itself)
PORT=8443
HP="$ADDR:$PORT"                             # the registry as the image names it (an address, so the lab needs no /etc/hosts)
ALIAS="lo:b75622952"
IMAGE="$HP/k8mtest/k8m:v1.0"
PAUSE_REF="$CASE_ID.local/pause:1"           # the sandbox image of the pod: imported, never pulled
CTD_VERSION="1.6.17"                         # the containerd of the question
RUNC_VERSION="v1.1.12"
CRICTL_VERSION="v1.34.0"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"
        CTD_SHA="5f0584d000769d0cf08fc0e25135614ef5bf52971a6069175c78437699f3b8d4"
        RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8"
        CRICTL_SHA="a8ff2a3edb37a98daf3aba7c3b284fe0aa5bff24166d896ab9ef64c8913c9f51" ;;
    aarch64|arm64)  KARCH="arm64"
        CTD_SHA="7e110faa738bff2f5f0ffd54c4ec2c17c05fd2af6de4877c839794ca3dadd61c"
        RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8"
        CRICTL_SHA="c31d252e203df5f4cf37f314bd3092eb79087e791631c1e607087c74b6d0423f" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, openssl, curl, tar, sudo, sha256sum, gcc..."
for c in python3 openssl curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
echo "  host: $(uname -m), kernel $(uname -r), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$PODS" "$PKI" "$FRONT" "$FRONT/data/blobs/sha256" "$RUN" "$RUN/log"
sudo sh -c "find /sys/fs/cgroup -type d -path '*/$CASE_ID' 2>/dev/null | sort > '$STATE_DIR/cgroups.before'"
sudo sh -c "sha256sum /etc/ssl/certs/ca-certificates.crt 2>/dev/null > '$STATE_DIR/systemca.sha'" || true

sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION, runc $RUNC_VERSION and crictl $CRICTL_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "runc.$KARCH.$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
fetch "crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" "$CRICTL_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
for b in containerd containerd-shim-runc-v2 ctr; do sudo install -m 755 -o root -g root "$WORK_DIR/x/bin/$b" "$NODEBIN/$b"; done
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
tar -xzf "$CACHE/crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" crictl
sudo install -m 755 -o root -g root "$WORK_DIR/x/crictl" "$BIN/crictl.real"
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version), runc $("$NODEBIN/runc" --version | head -1), $("$BIN/crictl.real" --version)"

echo "[setup] the registry's address $ADDR (an alias of lo, no 'ip' needed) and the port $PORT..."
sudo tee "$STATE_DIR/alias.py" >/dev/null <<'ALIAS_PY_EOF'
"""alias.py add|del|has IFACE:LABEL IP : an address as an alias of the loopback interface (a /32, no `ip` binary needed). It is not in 127.0.0.0/8, so containerd does not take it for a loopback registry (plain HTTP)."""
import fcntl
import socket
import struct
import sys

SIOCSIFADDR, SIOCSIFFLAGS, SIOCSIFNETMASK = 0x8916, 0x8914, 0x891C


def has(ip):
    return any(ln.strip() == "|-- " + ip for ln in open("/proc/net/fib_trie"))


def ifreq(name, addr):
    return struct.pack("16sH2x4s8x", name.encode(), socket.AF_INET, socket.inet_aton(addr))


cmd, name, ip = sys.argv[1:4]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
if cmd == "has":
    sys.exit(0 if has(ip) else 1)
if cmd == "add":
    if has(ip):
        sys.exit("%s is already an address of this host" % ip)
    fcntl.ioctl(s, SIOCSIFADDR, ifreq(name, ip))
    fcntl.ioctl(s, SIOCSIFNETMASK, ifreq(name, "255.255.255.255"))
    fcntl.ioctl(s, SIOCSIFFLAGS, struct.pack("16sH14x", name.encode(), 0x1 | 0x40))
elif cmd == "del":
    try:
        fcntl.ioctl(s, SIOCSIFFLAGS, struct.pack("16sH14x", name.encode(), 0))
    except OSError:
        pass
ALIAS_PY_EOF
sudo python3 "$STATE_DIR/alias.py" add "$ALIAS" "$ADDR" || { echo "[setup] ERROR: cannot add the address $ADDR to lo"; exit 1; }

echo "[setup] the certificates: the lab's CA and a server certificate for $ADDR, and a second CA with a certificate of the same name that nothing trusts (the front can show it, to prove that a client verifies)..."
mkpki() {   # $1 = prefix: a CA ($1-ca) and a server certificate ($1)
    local d="$PKI" p="$1"
    openssl genrsa -out "$d/$p-ca.key" 2048 2>/dev/null
    openssl req -x509 -new -nodes -sha256 -days 3650 -subj "/C=CN/O=example/CN=$p lab CA" -key "$d/$p-ca.key" -out "$d/$p-ca.crt" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" 2>/dev/null
    openssl genrsa -out "$d/$p.key" 2048 2>/dev/null
    openssl req -new -sha256 -subj "/C=CN/O=example/CN=$ADDR" -key "$d/$p.key" -out "$d/$p.csr" 2>/dev/null
    printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:%s,DNS:plzharbor.com\nauthorityKeyIdentifier=keyid,issuer\nsubjectKeyIdentifier=hash\n' "$ADDR" > "$d/$p.ext"
    openssl x509 -req -sha256 -days 3650 -extfile "$d/$p.ext" -CA "$d/$p-ca.crt" -CAkey "$d/$p-ca.key" -CAcreateserial -in "$d/$p.csr" -out "$d/$p.crt" 2>/dev/null
}
sudo bash -c "$(declare -f mkpki); ADDR='$ADDR'; PKI='$PKI'; mkpki lab; mkpki rogue"
sudo cp "$PKI/lab-ca.crt" "$PKI/ca.crt"
sudo openssl verify -CAfile "$PKI/ca.crt" "$PKI/lab.crt" >/dev/null || { echo "[setup] ERROR: the lab's certificate does not chain to its CA"; exit 1; }
sudo chmod 644 "$PKI"/*.crt; sudo chmod 600 "$PKI"/*.key

echo "[setup] the image of the registry (a static program that prints a per-run token), built offline; and the sandbox image of the node's pod..."
TOKEN=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifndef TOKEN
#define TOKEN "none"
#endif

int main(int argc, char **argv) {
    const char *n = strrchr(argv[0], '/');
    n = n ? n + 1 : argv[0];
    if (!strcmp(n, "pause")) for (;;) pause();
    for (;;) { printf("bench75622952 %s\n", TOKEN); fflush(stdout); sleep(2); }
}
APP_C_EOF
sudo gcc -static -Os -s -w -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTDIR REF ENTRYPOINT_JSON BIN FILE... : an OCI image layout in OUTDIR (oci-layout, index.json, blobs/sha256/*) with one layer: BIN as the first FILE, the others are links to it."""
import hashlib
import io
import json
import os
import platform
import sys
import tarfile

out, ref, entry, binary = sys.argv[1:5]
names = sys.argv[5:]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
T = 1700000000


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for d in ("bin", "etc", "proc", "dev", "sys", "tmp"):
        ti = tarfile.TarInfo(d)
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, T
        t.addfile(ti)
    data = open(binary, "rb").read()
    ti = tarfile.TarInfo(names[0])
    ti.size, ti.mode, ti.mtime = len(data), 0o755, T
    t.addfile(ti, io.BytesIO(data))
    for n in names[1:]:
        ti = tarfile.TarInfo(n)
        ti.type, ti.linkname, ti.mode, ti.mtime = tarfile.SYMTYPE, "/" + names[0], 0o777, T
        t.addfile(ti)
layer = buf.getvalue()
cfg = {"architecture": arch, "os": "linux", "config": {"Entrypoint": json.loads(entry)}, "rootfs": {"type": "layers", "diff_ids": [sha(layer)]},
       "history": [{"created_by": "COPY app /app"}]}
config = json.dumps(cfg).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(layer), "size": len(layer)}]}).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
os.makedirs(out + "/blobs/sha256", exist_ok=True)
for name, blob in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(layer)[7:], layer),
                   ("blobs/sha256/" + sha(config)[7:], config), ("blobs/sha256/" + sha(manifest)[7:], manifest)):
    open(out + "/" + name, "wb").write(blob)
print(sha(manifest))
MKIMG_PY_EOF
MANIFEST=$(sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/app-layout" "$IMAGE" '["/app"]' "$STATE_DIR/app" bin/app app)
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause-layout" "$PAUSE_REF" '["/pause"]' "$STATE_DIR/app" bin/pause pause >/dev/null
sudo tar -C "$STATE_DIR/pause-layout" -cf "$STATE_DIR/pause.tar" .
sudo sh -c "cp '$STATE_DIR'/app-layout/blobs/sha256/* '$FRONT/data/blobs/sha256/'"
sudo sh -c "printf '{\"k8mtest/k8m:v1.0\": \"%s\"}' '$MANIFEST' > '$FRONT/data/tags.json'"
echo "  the image $IMAGE: manifest $MANIFEST"

echo "[setup] the registry front: a stand-in for the nginx of a Harbor 2.5 (routes only: /v2/ is the registry with Bearer tokens, /service/token checks the account, everything else is the portal page); TLS from the lab's CA..."
sudo tee "$FRONT/front.py" >/dev/null <<'FRONT_PY_EOF'
"""front.py LIB RUN ADDR PORT : the lab's stand-in for the nginx of a Harbor 2.5, routes only.
  /v2/...             the registry API: manifests and blobs of the one image in data/, a Bearer token is needed (401 with the challenge otherwise)
  /service/token      the token service: Basic admin / Harbor12345 (GET; POST is 405, like Harbor's: clients fall back to GET)
  everything else     the portal: the page of the single page application, "200 text/html" for ANY path (the catch-all of Harbor's portal)
TLS: the certificate of the file RUN/front.mode on each connection: "lab" (signed by the lab's CA) or "rogue" (the same name, signed by a CA nobody trusts).
Every request is a line of RUN/front.log (JSON): time, method, path, status, content type, kind of authorization (none, basic-ok, basic-bad, bearer-ok, bearer-bad), User-Agent, TLS mode."""
import base64
import hashlib
import hmac
import http.server
import json
import os
import re
import socket
import socketserver
import ssl
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

LIB, RUN, ADDR, PORT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
DATA = LIB + "/front/data"
PKI = LIB + "/pki"
SECRET = os.urandom(16)
USER, PASSWORD = "admin", "Harbor12345"
PORTAL = (b'<!doctype html>\n<html lang="en">\n<head>\n  <meta charset="utf-8">\n  <title>Harbor</title>\n  <base href="/">\n  <meta name="viewport" content="width=device-width, initial-scale=1">\n'
          b'  <link rel="icon" type="image/x-icon" href="favicon.ico?v=2">\n</head>\n<body>\n  <harbor-app>\n  </harbor-app>\n  <script src="runtime.js" defer></script>\n</body>\n</html>\n')
TAGS = json.load(open(DATA + "/tags.json"))
REPO = "k8mtest/k8m"
LOCK = threading.Lock()
CTX = {}
for mode, prefix in (("lab", "lab"), ("rogue", "rogue")):
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.load_cert_chain("%s/%s.crt" % (PKI, prefix), "%s/%s.key" % (PKI, prefix))
    CTX[mode] = c


def log(**kw):
    kw["t"] = round(time.time(), 3)
    with LOCK:
        with open(RUN + "/front.log", "a") as f:
            f.write(json.dumps(kw, sort_keys=True) + "\n")


def mode():
    try:
        m = open(RUN + "/front.mode").read().strip()
    except OSError:
        m = "lab"
    return m if m in CTX else "lab"


def make_token(access):
    body = base64.urlsafe_b64encode(json.dumps({"exp": time.time() + 300, "access": access}).encode()).decode()
    return body + "." + hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()


def check_token(tok):
    try:
        body, sig = tok.split(".")
        if not hmac.compare_digest(sig, hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()):
            return None
        d = json.loads(base64.urlsafe_b64decode(body))
        return d if d["exp"] > time.time() else None
    except Exception:
        return None


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "nginx"
    sys_version = ""

    def setup(self):
        self.request.settimeout(20)
        try:
            self.request.do_handshake()
        except (ssl.SSLError, OSError) as e:
            log(tls="failed", mode=mode(), error=str(e)[:80])
            raise
        super().setup()

    def log_message(self, *a):
        pass

    def send(self, code, ctype, body, extra=(), auth="none"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        log(method=self.command, path=self.path, status=code, ctype=ctype, auth=auth, ua=self.headers.get("User-Agent", ""), tls=mode())

    def err(self, code, msg, extra=(), auth="none"):
        body = json.dumps({"errors": [{"code": msg.upper().replace(" ", "_"), "message": msg}]}).encode()
        self.send(code, "application/json; charset=utf-8", body, extra, auth)

    def authz(self):
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic "):
            try:
                u, p = base64.b64decode(h[6:]).decode().split(":", 1)
            except Exception:
                return "basic-bad", None
            return ("basic-ok" if (u, p) == (USER, PASSWORD) else "basic-bad"), None
        if h.startswith("Bearer "):
            d = check_token(h[7:])
            return ("bearer-ok" if d else "bearer-bad"), d
        return "none", None

    def challenge(self, scope=None, auth="none"):
        c = 'Bearer realm="https://%s:%d/service/token",service="harbor-registry"' % (ADDR, PORT)
        if scope:
            c += ',scope="%s"' % scope
        self.err(401, "unauthorized", [("Www-Authenticate", c), ("Docker-Distribution-Api-Version", "registry/2.0")], auth)

    def do_HEAD(self):
        self.route()

    def do_GET(self):
        self.route()

    def do_POST(self):
        u = urlsplit(self.path)
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        if u.path == "/service/token":
            self.err(405, "method not allowed", auth=self.authz()[0])
        else:
            self.send(405, "text/html", b"<html><body>405</body></html>")

    def route(self):
        u = urlsplit(self.path)
        p = u.path
        if p == "/service/token":
            kind, _ = self.authz()
            if kind != "basic-ok":
                return self.err(401, "unauthorized", [("Www-Authenticate", 'Basic realm="harbor-token-service"')], kind)
            q = parse_qs(u.query)
            access = []
            for s in q.get("scope", []):
                m = re.match(r"repository:([^:]+):(.+)$", s)
                if m:
                    access.append({"name": m.group(1), "actions": m.group(2).split(",")})
            t = make_token(access)
            body = json.dumps({"token": t, "access_token": t, "expires_in": 300, "issued_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}).encode()
            return self.send(200, "application/json; charset=utf-8", body, auth=kind)
        if p in ("/v2/", "/v2"):
            kind, d = self.authz()
            if kind != "bearer-ok":
                return self.challenge(auth=kind)
            return self.send(200, "application/json; charset=utf-8", b"{}", [("Docker-Distribution-Api-Version", "registry/2.0")], kind)
        m = re.match(r"/v2/(.+)/(manifests|blobs)/([^/]+)$", p)
        if m:
            name, what, ref = m.groups()
            scope = "repository:%s:pull" % name
            kind, d = self.authz()
            if kind != "bearer-ok" or not any(a["name"] == name and "pull" in a["actions"] for a in d["access"]):
                return self.challenge(scope, kind)
            if name != REPO:
                return self.err(404, "name unknown", auth=kind)
            if what == "manifests":
                digest = TAGS.get("%s:%s" % (name, ref), ref if ref.startswith("sha256:") else "")
                f = DATA + "/blobs/sha256/" + digest[7:]
                if not digest.startswith("sha256:") or not os.path.exists(f):
                    return self.err(404, "manifest unknown", auth=kind)
                body = open(f, "rb").read()
                return self.send(200, json.loads(body)["mediaType"], body, [("Docker-Content-Digest", digest), ("Docker-Distribution-Api-Version", "registry/2.0")], kind)
            f = DATA + "/blobs/sha256/" + ref[7:]
            if not re.match(r"sha256:[0-9a-f]{64}$", ref) or not os.path.exists(f):
                return self.err(404, "blob unknown", auth=kind)
            return self.send(200, "application/octet-stream", open(f, "rb").read(), [("Docker-Content-Digest", ref)], kind)
        if p == "/api/v2.0/ping":
            return self.send(200, "text/plain; charset=utf-8", b"Pong")
        self.send(200, "text/html", PORTAL, auth=self.authz()[0])


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def get_request(self):
        sock, addr = self.socket.accept()
        return CTX[mode()].wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr

    def handle_error(self, request, client_address):
        pass


open(RUN + "/front.pid", "w").write(str(os.getpid()))
log(started=True, addr=ADDR, port=PORT)
S((ADDR, PORT), H).serve_forever()
FRONT_PY_EOF
sudo chmod 644 "$FRONT/front.py"
sudo sh -c "echo lab > '$RUN/front.mode'"
sudo env PYTHONUNBUFFERED=1 setsid -f sh -c 'exec python3 "$1" "$2" "$3" "$4" "$5" >> "$3/front.err" 2>&1' _ "$FRONT/front.py" "$LIB" "$RUN" "$ADDR" "$PORT" < /dev/null
for _ in $(seq 20); do curl -s --max-time 2 --cacert "$PKI/ca.crt" -o /dev/null "https://$HP/v2/" && break; sleep 0.5; done
curl -s --max-time 2 --cacert "$PKI/ca.crt" -o /dev/null "https://$HP/v2/" || { echo "[setup] ERROR: the front does not answer at https://$HP/v2/"; sudo tail -5 "$RUN/front.err" 2>/dev/null; exit 1; }
echo "[setup] ctr, crictl, nodectl and the pod's definition..."
sudo tee "$BIN/ctr" >/dev/null <<CEOF
#!/bin/sh
exec $NODEBIN/ctr -a $RUN/containerd.sock "\$@"
CEOF
sudo tee "$BIN/crictl" >/dev/null <<CEOF
#!/bin/sh
# crictl for the node's containerd (the machine's own crictl configuration is not used)
exec $BIN/crictl.real -r unix://$RUN/containerd.sock -i unix://$RUN/containerd.sock "\$@"
CEOF
sudo tee "$BIN/nodectl" >/dev/null <<CEOF
#!/bin/bash
# nodectl start|stop|restart|status : starts and stops the node's containerd (configuration $ETC/containerd.toml, read at the start; the PATH of the node starts with $NODEBIN). Must run as root.
PIDF="$RUN/containerd.pid"
SOCK="$RUN/containerd.sock"
[ "\$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "\$SOCK" ] && timeout 3 $BIN/crictl version >/dev/null 2>&1; }
case "\${1:-}" in
    start)
        if running; then echo "nodectl: containerd is already running (pid \$(pid))"; exit 0; fi
        mkdir -p "$RUN" "$LIB/containerd"
        setsid -f bash -c 'echo \$\$ > "\$1"; exec env -i PATH="$NODEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" containerd --config "\$2"' _ "\$PIDF" "$ETC/containerd.toml" >> "$RUN/containerd.log" 2>&1 < /dev/null
        for _ in \$(seq 60); do up && { echo "nodectl: containerd started (pid \$(pid))"; exit 0; }; sleep 0.5; done
        echo "nodectl: containerd did not answer on \$SOCK within 30 s; see $RUN/containerd.log" >&2; exit 1 ;;
    stop)
        p=\$(pid) || true
        if [ -n "\$p" ] && running; then
            kill -TERM "\$p" 2>/dev/null
            for _ in \$(seq 60); do kill -0 "\$p" 2>/dev/null || break; sleep 0.5; done
            kill -0 "\$p" 2>/dev/null && kill -KILL "\$p" 2>/dev/null
        fi
        rm -f "\$PIDF" "\$SOCK" "\$SOCK.ttrpc"
        echo "nodectl: containerd stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) if running; then echo "containerd is running (pid \$(pid))"; else echo "containerd is not running"; exit 1; fi ;;
    *) echo "usage: nodectl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
sudo chmod 755 "$BIN/ctr" "$BIN/crictl" "$BIN/nodectl"
sudo tee "$PODS/pod.json" >/dev/null <<PEOF
{
  "metadata": {"name": "k8m", "namespace": "default", "uid": "k8m-uid", "attempt": 1},
  "log_directory": "$RUN/log",
  "linux": {"cgroup_parent": "/$CASE_ID", "security_context": {"namespace_options": {"network": 2}}}
}
PEOF
sudo tee "$PODS/ctr.json" >/dev/null <<CEOF
{
  "metadata": {"name": "k8m"},
  "image": {"image": "$IMAGE"},
  "log_path": "k8m.log",
  "linux": {}
}
CEOF

echo "[setup] the node's configuration: containerd's default (config version 2, as the question's), the node's directories, a local sandbox image, and the registry settings OF THE QUESTION (CA file, account, and a mirror with the endpoint https://$HP/)..."
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'CONFIG_PY_EOF'
"""patch_config.py LIB RUN PAUSE ADDR_PORT PKI < default.toml > containerd.toml : containerd 1.6's default configuration with the node's directories (root, state, socket), a local sandbox image, runc on the
cgroupfs driver with its own root, no CNI plugins of the machine, and the registry settings of the question: configs.<host>.tls (CA, no skipping of the verification), configs.<host>.auth (admin) and
mirrors.<host> with the endpoint "https://<host>/" (the trailing slash is the question's)."""
import re
import sys

lib, run, pause, hp, pki = sys.argv[1:6]
section = ""
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).replace('"', "")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    out = None
    if section == "" and k == "root":
        out = f'root = "{lib}/containerd"\n'
    elif section == "" and k == "state":
        out = f'state = "{run}/containerd"\n'
    elif section == "grpc" and k == "address":
        out = f'{indent}address = "{run}/containerd.sock"\n'
    elif section == "ttrpc" and k == "address":
        out = f'{indent}address = "{run}/containerd.sock.ttrpc"\n'
    elif k == "restrict_oom_score_adj":
        out = f"{indent}restrict_oom_score_adj = true\n"
    elif k == "sandbox_image":
        out = f'{indent}sandbox_image = "{pause}"\n'
    elif section.endswith("grpc.v1.cri.cni") and k == "bin_dir":
        out = f'{indent}bin_dir = "{lib}/cni/bin"\n'
    elif section.endswith("grpc.v1.cri.cni") and k == "conf_dir":
        out = f'{indent}conf_dir = "{lib}/cni/net.d"\n'
    elif section.endswith("runtimes.runc.options") and k == "Root":
        out = f'{indent}Root = "{run}/runc"\n'
    sys.stdout.write(out or line)
    if section.endswith("grpc.v1.cri.registry.configs") and m:
        sys.stdout.write(f'''        [plugins."io.containerd.grpc.v1.cri".registry.configs."{hp}"]
          [plugins."io.containerd.grpc.v1.cri".registry.configs."{hp}".tls]
            insecure_skip_verify = false
            ca_file = "{pki}/ca.crt"
          [plugins."io.containerd.grpc.v1.cri".registry.configs."{hp}".auth]
            username = "admin"
            password = "Harbor12345"
''')
    if section.endswith("grpc.v1.cri.registry.mirrors") and m:
        sys.stdout.write(f'''        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."{hp}"]
          endpoint = ["https://{hp}/"]
''')
CONFIG_PY_EOF
sudo env PATH="$NODEBIN:$PATH" containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$LIB" "$RUN" "$PAUSE_REF" "$HP" "$PKI" | sudo tee "$ETC/containerd.toml" >/dev/null
sudo grep -q "endpoint = \[\"https://$HP/\"\]" "$ETC/containerd.toml" && sudo grep -q "Root = \"$RUN/runc\"" "$ETC/containerd.toml" && sudo grep -q "sandbox_image = \"$PAUSE_REF\"" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not write the node's configuration"; exit 1; }
sudo cp "$ETC/containerd.toml" "$STATE_DIR/containerd.toml.seed"

echo "[setup] starting the node and importing the sandbox image (offline)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }
sudo "$BIN/crictl" inspecti "$PAUSE_REF" >/dev/null 2>&1 || { echo "[setup] ERROR: the sandbox image is not in the node"; exit 1; }

echo "[setup] the record of what is true (hashes of the lab's files and of the image data, the process of the front, the image's manifest digest, the portal page's digest, the token)..."
sudo sh -c "printf '%s' '$MANIFEST' > '$STATE_DIR/manifest.digest'; printf '%s' '$TOKEN' > '$STATE_DIR/token'"
sudo python3 -c "
import hashlib, re
s = open('$FRONT/front.py').read()
m = re.search(r\"PORTAL = \((.*?)\)\nTAGS\", s, re.S)
print('sha256:' + hashlib.sha256(eval('(' + m.group(1) + ')')).hexdigest())" | sudo tee "$STATE_DIR/portal.digest" >/dev/null
sudo sh -c "cd / && { sha256sum '$NODEBIN/containerd' '$NODEBIN/containerd-shim-runc-v2' '$NODEBIN/runc' '$NODEBIN/ctr' '$BIN/crictl.real' '$BIN/crictl' '$BIN/ctr' '$BIN/nodectl' '$FRONT/front.py' '$PKI'/*.crt '$PKI'/*.key '$PODS/pod.json' '$PODS/ctr.json' '$STATE_DIR/manifest.digest'; find '$FRONT/data' -type f | sort | xargs sha256sum; } > '$STATE_DIR/lab.sha'"
sudo sh -c "readlink /proc/\$(cat '$RUN/front.pid')/exe > '$STATE_DIR/front.exe'; cat '$RUN/front.pid' > '$STATE_DIR/front.pid'"

echo "[setup] done. The registry is https://$HP (the lab's CA: $PKI/ca.crt); the image is $IMAGE; the node: $BIN/nodectl and $BIN/crictl (with sudo), its configuration $ETC/containerd.toml."
