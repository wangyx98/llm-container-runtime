#!/bin/bash
set -e

CASE_ID="bench68630845"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node (containerd's root, its programs, the pod's definitions, the tools), the registry (its program, configuration, data) and the web application's stand-in
RUN="/run/$CASE_ID"                          # containerd's state and socket, the logs and pid files of the registry and of the web application
CACHE="/var/cache/$CASE_ID"                  # the downloaded containerd, runc, crictl and registry (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl, crictl, ctr (with the node's socket)
NODEBIN="$LIB/node/bin"                      # first in the PATH of the node's containerd: containerd, its shim and runc are found here
ETC="$LIB/etc"                               # containerd.toml: THE file of the task
PKI="$LIB/pki"
WEB="$LIB/web"                               # the stand-in of GitLab's web application (port 443)
REG="$LIB/registry"                          # the real container registry (distribution), port 5050
PODS="$LIB/pods"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
ADDR="10.68.63.45"                           # the GitLab host: a /32 alias of lo (the image names an address, so the lab needs no /etc/hosts)
ALIAS="lo:b68630845"
REGPORT=5050                                 # the registry's port (GitLab's default for a separate registry address); the web application is on 443
HP="$ADDR:$REGPORT"                          # the registry as the image names it
REPO="lab-user/webapp/nginx"
IMAGE="$HP/$REPO:v1"
PAUSE_REF="$CASE_ID.local/pause:1"           # the sandbox image of the pod: imported, never pulled
CTD_VERSION="1.6.17"
RUNC_VERSION="v1.1.12"
CRICTL_VERSION="v1.34.0"
REG_VERSION="2.8.3"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"
        CTD_SHA="5f0584d000769d0cf08fc0e25135614ef5bf52971a6069175c78437699f3b8d4"
        RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8"
        CRICTL_SHA="a8ff2a3edb37a98daf3aba7c3b284fe0aa5bff24166d896ab9ef64c8913c9f51"
        REG_SHA="b1f750ecbe09f38e2143e22c61a25e3da2afe1510d9522859230b480e642ceff" ;;
    aarch64|arm64)  KARCH="arm64"
        CTD_SHA="7e110faa738bff2f5f0ffd54c4ec2c17c05fd2af6de4877c839794ca3dadd61c"
        RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8"
        CRICTL_SHA="c31d252e203df5f4cf37f314bd3092eb79087e791631c1e607087c74b6d0423f"
        REG_SHA="7d2252eeeac97dd60fb9b36bebd15b95d7f947c4c82b8e0824cb55233ece9cd0" ;;
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
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$PODS" "$PKI" "$WEB" "$REG" "$REG/data" "$RUN" "$RUN/log"
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
echo "[setup] containerd $CTD_VERSION, runc $RUNC_VERSION, crictl $CRICTL_VERSION and the registry $REG_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "runc.$KARCH.$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
fetch "crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" "$CRICTL_SHA"
fetch "registry_${REG_VERSION}_linux_$KARCH.tar.gz" "https://github.com/distribution/distribution/releases/download/v$REG_VERSION/registry_${REG_VERSION}_linux_$KARCH.tar.gz" "$REG_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
for b in containerd containerd-shim-runc-v2 ctr; do sudo install -m 755 -o root -g root "$WORK_DIR/x/bin/$b" "$NODEBIN/$b"; done
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
tar -xzf "$CACHE/crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" crictl
sudo install -m 755 -o root -g root "$WORK_DIR/x/crictl" "$BIN/crictl.real"
tar -xzf "$CACHE/registry_${REG_VERSION}_linux_$KARCH.tar.gz" -C "$WORK_DIR/x" registry
sudo install -m 755 -o root -g root "$WORK_DIR/x/registry" "$REG/registry"
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version), runc $("$NODEBIN/runc" --version | head -1), $("$BIN/crictl.real" --version), $("$REG/registry" --version)"

echo "[setup] the GitLab host's address $ADDR (an alias of lo, no 'ip' needed); ports 443 and $REGPORT must be free..."
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

sudo python3 -I - "$REGPORT" <<'PORT_PY_EOF' || { echo "[setup] ERROR: a port the lab needs (443 or $REGPORT) is already listening on this host"; exit 1; }
import sys
busy = [int(p, 16) for l in open("/proc/net/tcp").readlines()[1:] for f in [l.split()] if f[3] == "0A" for p in [f[1].split(":")[1]]]
sys.exit(1 if 443 in busy or int(sys.argv[1]) in busy else 0)
PORT_PY_EOF
echo "[setup] the certificates: the lab's CA and a server certificate for $ADDR (the registry and the web application use it), and the key and certificate with which the web application signs the registry's tokens..."
sudo openssl genrsa -out "$PKI/ca.key" 2048 2>/dev/null
sudo openssl req -x509 -new -nodes -sha256 -days 3650 -subj "/C=CN/O=example/CN=lab CA" -key "$PKI/ca.key" -out "$PKI/ca.crt" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" 2>/dev/null
sudo openssl genrsa -out "$PKI/server.key" 2048 2>/dev/null
sudo openssl req -new -sha256 -subj "/C=CN/O=example/CN=$ADDR" -key "$PKI/server.key" -out "$PKI/server.csr" 2>/dev/null
sudo sh -c "printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:$ADDR\nauthorityKeyIdentifier=keyid,issuer\nsubjectKeyIdentifier=hash\n' > '$PKI/server.ext'"
sudo openssl x509 -req -sha256 -days 3650 -extfile "$PKI/server.ext" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial -in "$PKI/server.csr" -out "$PKI/server.crt" 2>/dev/null
sudo openssl verify -CAfile "$PKI/ca.crt" "$PKI/server.crt" >/dev/null || { echo "[setup] ERROR: the server certificate does not chain to the lab's CA"; exit 1; }
sudo openssl genrsa -out "$PKI/jwt.key" 2048 2>/dev/null
sudo openssl req -x509 -new -sha256 -days 3650 -subj "/CN=lab token signer" -key "$PKI/jwt.key" -out "$PKI/jwt.crt" 2>/dev/null
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
    for (;;) { printf("bench68630845 %s\n", TOKEN); fflush(stdout); sleep(2); }
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
echo "  the image $IMAGE: manifest $MANIFEST"

echo "[setup] the registry (the real distribution $REG_VERSION, TLS from the lab's CA): first without authentication for the push of the image, as docker push does it..."
sudo tee "$STATE_DIR/push.py" >/dev/null <<'PUSH_PY_EOF'
"""push.py ADDR PORT REPO LAYOUT CA : pushes the image of an OCI layout (blobs by POST + PUT ?digest=, then the manifest under the tag v1) the way docker push does; prints the manifest digest the registry reports."""
import json
import ssl
import sys
import urllib.request

addr, port, repo, layout, ca = sys.argv[1:6]
ctx = ssl.create_default_context(cafile=ca)
base = "https://%s:%s" % (addr, port)


def req(method, url, data=None, headers=None):
    return urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=headers or {}), context=ctx, timeout=30)


digest = json.load(open(layout + "/index.json"))["manifests"][0]["digest"]
manifest = open(layout + "/blobs/sha256/" + digest[7:], "rb").read()
m = json.loads(manifest)
for d in [m["config"]] + m["layers"]:
    data = open(layout + "/blobs/sha256/" + d["digest"][7:], "rb").read()
    loc = req("POST", "%s/v2/%s/blobs/uploads/" % (base, repo), b"").headers["Location"]
    if loc.startswith("/"):
        loc = base + loc
    req("PUT", "%s%sdigest=%s" % (loc, "&" if "?" in loc else "?", d["digest"]), data, {"Content-Type": "application/octet-stream"})
r = req("PUT", "%s/v2/%s/manifests/v1" % (base, repo), manifest, {"Content-Type": m["mediaType"]})
print(r.headers["Docker-Content-Digest"])
PUSH_PY_EOF
regconf() {   # $1 = yes: the token authentication of a GitLab registry (the realm is the web application on port 443)
    sudo tee "$REG/config.yml" >/dev/null <<REG_CONF_EOF
version: 0.1
log:
  level: info
  formatter: text
storage:
  filesystem:
    rootdirectory: $REG/data
http:
  addr: $ADDR:$REGPORT
  secret: lab-registry-secret
  tls:
    certificate: $PKI/server.crt
    key: $PKI/server.key
REG_CONF_EOF
    if [ "$1" = yes ]; then
        sudo tee -a "$REG/config.yml" >/dev/null <<REG_AUTH_EOF
auth:
  token:
    realm: https://$ADDR/jwt/auth
    service: container_registry
    issuer: lab-gitlab
    rootcertbundle: $PKI/jwt.crt
REG_AUTH_EOF
    fi
}
start_registry() {
    sudo setsid -f sh -c 'echo $$ > "$1"; exec "$2" serve "$3" >> "$4" 2>&1' _ "$RUN/registry.pid" "$REG/registry" "$REG/config.yml" "$RUN/registry.log" < /dev/null
    for _ in $(seq 40); do
        code=$(curl -s --max-time 2 --cacert "$PKI/ca.crt" -o /dev/null -w '%{http_code}' "https://$ADDR:$REGPORT/v2/" 2>/dev/null) || true
        [ "$code" = 200 ] || [ "$code" = 401 ] && return 0
        sleep 0.5
    done
    echo "[setup] ERROR: the registry does not answer at https://$ADDR:$REGPORT/v2/"; sudo tail -5 "$RUN/registry.log" 2>/dev/null; exit 1
}
regconf no
start_registry
PUSHED=$(sudo python3 "$STATE_DIR/push.py" "$ADDR" "$REGPORT" "$REPO" "$STATE_DIR/app-layout" "$PKI/ca.crt") || { echo "[setup] ERROR: the push of the image failed"; sudo tail -5 "$RUN/registry.log"; exit 1; }
[ "$PUSHED" = "$MANIFEST" ] || { echo "[setup] ERROR: the registry reports the manifest digest $PUSHED, not $MANIFEST"; exit 1; }
sudo kill "$(sudo cat "$RUN/registry.pid")"
for _ in $(seq 20); do sudo kill -0 "$(sudo cat "$RUN/registry.pid")" 2>/dev/null || break; sleep 0.25; done
regconf yes
: | sudo tee "$RUN/registry.log" >/dev/null
start_registry
[ "$(curl -s --max-time 5 --cacert "$PKI/ca.crt" -o /dev/null -w '%{http_code}' "https://$ADDR:$REGPORT/v2/")" = 401 ] || { echo "[setup] ERROR: the registry does not ask for a token"; exit 1; }

echo "[setup] the web application's stand-in on https://$ADDR (port 443): the token service /jwt/auth of the registry, the sign-in page with its per-request CSRF token, and a redirect to the sign-in page for every other path of an anonymous client..."
sudo tee "$WEB/web.py" >/dev/null <<'WEB_PY_EOF'
"""web.py LIB RUN ADDR : the lab's stand-in for the web application of a GitLab host (NOT GitLab: routes only), https on ADDR:443 with the lab's certificate.
  /jwt/auth       the registry's token service (GET only: any other method is 404, so a client that tries POST first falls back to GET): GET with Basic (the deploy token) gives a token for the repositories asked for with "pull" (service container_registry); without an Authorization header an anonymous
                  token with no access; a wrong password is 401
  /users/sign_in  200 text/html: a sign-in page with a CSRF token that differs at every request
  everything else 302 to /users/sign_in (an anonymous client, as for any page of the application)
Every request is a line of RUN/web.log (JSON): time, method, path, status, content type, sha256 of the body of a 200 (also for HEAD), kind of authorization (none, basic-ok, basic-bad), User-Agent."""
import base64
import hashlib
import http.server
import json
import os
import re
import secrets
import socketserver
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

LIB, RUN, ADDR = sys.argv[1:4]
PKI = LIB + "/pki"
USER, PASSWORD = "gitlab+deploy-token-1", "k8s-pull-secret"
KID = open(PKI + "/jwt.kid").read().strip()
LOCK = threading.Lock()


def b64(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def log(**kw):
    kw["t"] = round(time.time(), 3)
    with LOCK:
        with open(RUN + "/web.log", "a") as f:
            f.write(json.dumps(kw, sort_keys=True) + "\n")


def make_token(sub, access):
    now = int(time.time())
    head = b64(json.dumps({"typ": "JWT", "alg": "RS256", "kid": KID}, separators=(",", ":")).encode())
    body = b64(json.dumps({"iss": "lab-gitlab", "sub": sub, "aud": "container_registry", "exp": now + 300, "nbf": now - 5, "iat": now,
                           "jti": secrets.token_hex(8), "access": access}, separators=(",", ":")).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", PKI + "/jwt.key"], input=(head + "." + body).encode(), capture_output=True, check=True).stdout
    return head + "." + body + "." + b64(sig)


def sign_in_page():
    return ('<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<title>Sign in</title>\n<meta name="csrf-param" content="authenticity_token" />\n'
            '<meta name="csrf-token" content="%s" />\n</head>\n<body class="login-page">\n<form class="new_user" id="new_user" action="/users/sign_in" method="post">\n'
            '<input type="hidden" name="authenticity_token" value="%s" />\n<input type="text" name="user[login]" id="user_login" />\n'
            '<input type="password" name="user[password]" id="user_password" />\n<button type="submit">Sign in</button>\n</form>\n</body>\n</html>\n'
            % (secrets.token_urlsafe(64), secrets.token_urlsafe(64))).encode()


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "lab-web"
    sys_version = ""

    def setup(self):
        self.request.settimeout(20)
        self.request.do_handshake()
        super().setup()

    def log_message(self, *a):
        pass

    def send(self, code, ctype, body, extra=(), auth="none", sha=None):
        self.send_response(code)
        if ctype:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        log(method=self.command, path=self.path, status=code, ctype=ctype or "", sha=sha, auth=auth, ua=self.headers.get("User-Agent", ""))

    def authz(self):
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic "):
            try:
                u, p = base64.b64decode(h[6:]).decode().split(":", 1)
            except Exception:
                return "basic-bad", None
            return ("basic-ok" if (u, p) == (USER, PASSWORD) else "basic-bad"), u
        return "none", None

    def route(self):
        u = urlsplit(self.path)
        if u.path == "/jwt/auth" and self.command != "GET":
            n = int(self.headers.get("Content-Length") or 0)
            if n:
                self.rfile.read(n)
            return self.send(404, "text/html; charset=utf-8", b"<html><body>The page could not be found</body></html>", auth=self.authz()[0])
        if u.path == "/jwt/auth":
            kind, user = self.authz()
            if kind == "basic-bad":
                body = json.dumps({"errors": [{"code": "UNAUTHORIZED", "message": "HTTP Basic: Access denied"}]}).encode()
                return self.send(401, "application/json", body, auth=kind)
            access = []
            for s in parse_qs(u.query).get("scope", []):
                m = re.match(r"repository:([^:]+):(.+)$", s)
                if m and kind == "basic-ok" and "pull" in m.group(2).split(","):
                    access.append({"type": "repository", "name": m.group(1), "actions": ["pull"]})
            t = make_token(user or "", access)
            body = json.dumps({"token": t, "access_token": t, "expires_in": 300}).encode()
            return self.send(200, "application/json", body, auth=kind)
        if u.path == "/users/sign_in":
            body = sign_in_page()
            return self.send(200, "text/html; charset=utf-8", body, auth=self.authz()[0], sha="sha256:" + hashlib.sha256(body).hexdigest())
        self.send(302, "", b"", [("Location", "/users/sign_in")], auth=self.authz()[0])

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = route


class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def get_request(self):
        sock, addr = self.socket.accept()
        return CTX.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr

    def handle_error(self, request, client_address):
        pass


CTX = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
CTX.load_cert_chain(PKI + "/server.crt", PKI + "/server.key")
open(RUN + "/web.pid", "w").write(str(os.getpid()))
log(started=True, addr=ADDR)
S((ADDR, 443), H).serve_forever()
WEB_PY_EOF
sudo chmod 644 "$WEB/web.py"
sudo sh -c "openssl pkey -in '$PKI/jwt.key' -pubout -outform DER | python3 -c \"
import base64, hashlib, sys
h = base64.b32encode(hashlib.sha256(sys.stdin.buffer.read()).digest()[:30]).decode()
print(':'.join(h[i:i + 4] for i in range(0, 48, 4)))\" > '$PKI/jwt.kid'"
sudo env PYTHONUNBUFFERED=1 setsid -f sh -c 'exec python3 "$1" "$2" "$3" "$4" >> "$3/web.err" 2>&1' _ "$WEB/web.py" "$LIB" "$RUN" "$ADDR" < /dev/null
for _ in $(seq 20); do curl -s --max-time 2 --cacert "$PKI/ca.crt" -o /dev/null "https://$ADDR/users/sign_in" && break; sleep 0.5; done
curl -s --max-time 2 --cacert "$PKI/ca.crt" -o /dev/null "https://$ADDR/users/sign_in" || { echo "[setup] ERROR: the web application does not answer at https://$ADDR/"; sudo tail -5 "$RUN/web.err" 2>/dev/null; exit 1; }
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
  "metadata": {"name": "webapp", "namespace": "default", "uid": "webapp-uid", "attempt": 1},
  "log_directory": "$RUN/log",
  "linux": {"cgroup_parent": "/$CASE_ID", "security_context": {"namespace_options": {"network": 2}}}
}
PEOF
sudo tee "$PODS/ctr.json" >/dev/null <<CEOF
{
  "metadata": {"name": "nginx"},
  "image": {"image": "$IMAGE"},
  "log_path": "nginx.log",
  "linux": {}
}
CEOF

echo "[setup] the node's configuration: containerd's default (config version 2), the node's directories, a local sandbox image, and the registry settings of the question: the CA for the host and for the host with the port, and a mirror of $HP whose endpoint is https://$ADDR (no port)..."
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'CONFIG_PY_EOF'
"""patch_config.py LIB RUN PAUSE ADDR HP PKI < default.toml > containerd.toml : containerd 1.6's default configuration with the node's directories (root, state, socket), a local sandbox image, runc with its own
root, no CNI plugins of the machine, and the registry settings of the question: configs.<host>.tls (the lab's CA, verification on) for ADDR and for ADDR:PORT, and mirrors.<ADDR:PORT> with the endpoint
"https://ADDR" (the port missing: the question's mistake)."""
import re
import sys

lib, run, pause, addr, hp, pki = sys.argv[1:7]
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
        for h in (addr, hp):
            sys.stdout.write(f'''        [plugins."io.containerd.grpc.v1.cri".registry.configs."{h}"]
          [plugins."io.containerd.grpc.v1.cri".registry.configs."{h}".tls]
            insecure_skip_verify = false
            ca_file = "{pki}/ca.crt"
''')
    if section.endswith("grpc.v1.cri.registry.mirrors") and m:
        sys.stdout.write(f'''        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."{hp}"]
          endpoint = ["https://{addr}"]
''')
CONFIG_PY_EOF
sudo env PATH="$NODEBIN:$PATH" containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$LIB" "$RUN" "$PAUSE_REF" "$ADDR" "$HP" "$PKI" | sudo tee "$ETC/containerd.toml" >/dev/null
sudo grep -q "endpoint = \[\"https://$ADDR\"\]" "$ETC/containerd.toml" && sudo grep -q "Root = \"$RUN/runc\"" "$ETC/containerd.toml" && sudo grep -q "sandbox_image = \"$PAUSE_REF\"" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not write the node's configuration"; exit 1; }
sudo cp "$ETC/containerd.toml" "$STATE_DIR/containerd.toml.seed"

echo "[setup] starting the node and importing the sandbox image (offline)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
sudo "$BIN/ctr" -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }
sudo "$BIN/crictl" inspecti "$PAUSE_REF" >/dev/null 2>&1 || { echo "[setup] ERROR: the sandbox image is not in the node"; exit 1; }

echo "[setup] the record of what is true (hashes of the lab's files and of the registry's data, the processes of the registry and of the web application, the image's manifest digest, the token)..."
sudo sh -c "printf '%s' '$MANIFEST' > '$STATE_DIR/manifest.digest'; printf '%s' '$TOKEN' > '$STATE_DIR/token'"
sudo sh -c "cd / && { sha256sum '$NODEBIN/containerd' '$NODEBIN/containerd-shim-runc-v2' '$NODEBIN/runc' '$NODEBIN/ctr' '$BIN/crictl.real' '$BIN/crictl' '$BIN/ctr' '$BIN/nodectl' '$REG/registry' '$REG/config.yml' '$WEB/web.py' '$PKI'/*.crt '$PKI'/*.key '$PKI/jwt.kid' '$PODS/pod.json' '$PODS/ctr.json' '$STATE_DIR/manifest.digest'; find '$REG/data' -type f | sort | xargs sha256sum; } > '$STATE_DIR/lab.sha'"
sudo sh -c "readlink /proc/\$(cat '$RUN/web.pid')/exe > '$STATE_DIR/web.exe'; cat '$RUN/web.pid' > '$STATE_DIR/web.pid'; readlink /proc/\$(cat '$RUN/registry.pid')/exe > '$STATE_DIR/registry.exe'; cat '$RUN/registry.pid' > '$STATE_DIR/registry.pid'"

echo "[setup] done. The GitLab host is $ADDR (web application on 443, registry on $REGPORT; the lab's CA: $PKI/ca.crt); the image is $IMAGE; the node: $BIN/nodectl and $BIN/crictl (with sudo), its configuration $ETC/containerd.toml."
