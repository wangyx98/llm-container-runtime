#!/bin/bash
set -e

CASE_ID="bench75817724"
RUN_BASE="/run/$CASE_ID"              # pid files and logs of k3s and of the two fixtures
LIB_BASE="/var/lib/$CASE_ID"          # control scripts, the CA of the registry, kubelet root (not in /run: it is mounted noexec on many hosts)
CTL_DIR="$LIB_BASE/bin"
REG_DIR="$RUN_BASE/registry"          # the private registry fixture: blobs, state.json, certificates, requests.log (root-owned)
REG_PORT=5000                         # HTTPS, the port of the question
REG_HOST="registry.bench75817724.test"   # its name: it resolves through the egress proxy only (no /etc/hosts entry)
HUB_DIR="$RUN_BASE/proxy"             # the egress proxy: reaches the registry by name, refuses (and logs) the rest
HUB_PORT=18097
PKI_DIR="$LIB_BASE/pki"               # the certificate of the CA that signed the registry's certificate (public part only)
REPO="hello-web"
TAG="latest"
IMAGE_REF="$REG_HOST:$REG_PORT/$REPO:$TAG"
PAUSE_REF="bench75817724.local/pause:1"   # sandbox ("pause") image of k3s, preloaded: no download at run time
NODE="bench75817724-node"
K3S_DATA="/var/lib/rancher/k3s"       # k3s' default data dir, as in the question

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

K3S_VERSION="v1.30.5+k3s1"
# release asset name and sha256 per architecture (sha256sum-<arch>.txt of the release)
case "$(uname -m)" in
    x86_64)          K3S_ASSET="k3s";       K3S_SHA256="322fbdc904deb1bf2f7a4460c0ae616db3aea75b8aefe911286946cdb0893d95" ;;
    aarch64|arm64)   K3S_ASSET="k3s-arm64"; K3S_SHA256="da3b23dc736401259f2e5ada5c481f8302d4f8a55b6d580e1abecaf85e89f2ac" ;;
    *)               K3S_ASSET=""; K3S_SHA256="" ;;
esac
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
OWNED_MARKER="$LIB_BASE/k3s_host_dirs_owned"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking curl, python3 and openssl are installed..."
for b in curl python3 openssl; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking this host has no k3s or kubelet of its own: k3s keeps files in fixed places"
echo "[setup] (/etc/rancher, /var/lib/rancher, /var/lib/kubelet, /run/k3s), which this case manages, and that ports"
echo "[setup] $REG_PORT and $HUB_PORT are free..."
for d in /etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s; do
    [ ! -e "$d" ] || { echo "[setup] ERROR: $d exists: this host has its own k3s or kubelet state, the case would damage it"; exit 1; }
done
for c in k3s-server k3s-agent kubelet; do
    ! pgrep -x "$c" >/dev/null 2>&1 || { echo "[setup] ERROR: a $c process runs on this host: the case needs a host without k3s or a kubelet"; exit 1; }
done
for p in $REG_PORT $HUB_PORT; do
    if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null || curl -sk --max-time 2 -o /dev/null "https://127.0.0.1:$p/" 2>/dev/null; then
        echo "[setup] ERROR: something already listens on 127.0.0.1:$p"; exit 1
    fi
done

echo "[setup] making sure gcc is available (gcc: two tiny static programs, the only files of the two images,"
echo "[setup] so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE" "$CTL_DIR" "$PKI_DIR"

echo "[setup] recording what /etc/containerd/certs.d (the docker-style place of the question) holds now: k3s does not use it, but a"
echo "[setup] solution may write there, and cleanup removes only what a solution adds..."
CERTS_DIR="/etc/containerd/certs.d"
if [ -d "$CERTS_DIR" ]; then
    ls -1 "$CERTS_DIR" | sudo tee "$LIB_BASE/certs.orig" >/dev/null
else
    sudo touch "$LIB_BASE/certs.absent"
fi
[ -d /etc/containerd ] || sudo touch "$LIB_BASE/etc_containerd.absent"
sudo touch "$OWNED_MARKER"      # from here on cleanup.sh may remove the fixed k3s directories

echo "[setup] locating the k3s binary (the one in the PATH; else $K3S_VERSION is downloaded, and its sha256"
echo "[setup] checked)..."
K3S_BIN="${BENCH75817724_K3S_BIN:-$(command -v k3s || true)}"
if [ -z "$K3S_BIN" ]; then
    [ -n "$K3S_ASSET" ] || { echo "[setup] ERROR: k3s is not installed and no binary is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
    # downloaded as the current user (not through sudo: sudo may drop the proxy settings of the user)
    curl -fsSL --retry 3 --max-time 300 -o "$STATE_DIR/k3s.download" \
        "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/$K3S_ASSET" \
        || { echo "[setup] ERROR: could not download k3s $K3S_VERSION"; exit 1; }
    echo "$K3S_SHA256  $STATE_DIR/k3s.download" | sha256sum -c - >/dev/null 2>&1 \
        || { echo "[setup] ERROR: the downloaded k3s has the wrong sha256"; exit 1; }
    sudo install -m 755 "$STATE_DIR/k3s.download" "$CTL_DIR/k3s"
    rm -f "$STATE_DIR/k3s.download"
    K3S_BIN="$CTL_DIR/k3s"
fi
[ -x "$K3S_BIN" ] || { echo "[setup] ERROR: $K3S_BIN is not executable"; exit 1; }
# whatever its origin, the case always reaches k3s under one path: $CTL_DIR/k3s (a link when k3s is installed elsewhere)
if [ "$K3S_BIN" != "$CTL_DIR/k3s" ]; then
    sudo ln -sf "$K3S_BIN" "$CTL_DIR/k3s"
    K3S_BIN="$CTL_DIR/k3s"
fi
echo "$K3S_BIN" > "$STATE_DIR/k3s.bin"
"$K3S_BIN" --version | head -1

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of
# the daemon itself (exec keeps the pid); setsid + all three fds redirected so it outlives this
# script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] building the two images offline, in DOCKER format (what docker push sends): hello-web, one static"
echo "[setup] program that prints a line with a per-run random token every 5 seconds and never exits, and the"
echo "[setup] sandbox image of the pods (a static program that only waits)..."
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    for (;;) {
        puts("bench75817724-hello-web-ok token=" TOKEN);
        sleep(5);
    }
}
CEOF
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
CEOF
gcc -static -Os -s -w -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/app" "$STATE_DIR/app.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause" "$STATE_DIR/pause.c"
sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$TOKEN" "$STATE_DIR/token"
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py push BASEURL REPO TAG BINARY ENTRY  : build a Docker image (one layer with BINARY as /ENTRY) and
push it to the registry with the plain distribution API (what `docker push` does)
   mkimg.py tar OUT REF BINARY ENTRY            : build the same into an OCI archive (for ctr images import)
Prints the digests as JSON."""
import base64
import gzip
import hashlib
import ssl
import io
import json
import os
import sys
import tarfile
import urllib.request

DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def build(binary, entry):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        data = open(binary, "rb").read()
        ti = tarfile.TarInfo(entry)
        ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        t.addfile(ti, io.BytesIO(data))
    layer = buf.getvalue()
    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
        g.write(layer)
    layer_gz = gz.getvalue()               # Docker layers are gzip: blob digest != diff id
    config = json.dumps({
        "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "docker_version": "20.10.21",
        "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
                   "Entrypoint": ["/" + entry], "Cmd": [], "WorkingDir": "/"},
        "container_config": {"Cmd": ["/bin/sh", "-c", "#(nop) ", "ENTRYPOINT [\"/%s\"]" % entry]},
        "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY %s / # buildkit" % entry},
                    {"created": "2023-11-14T22:13:20Z", "created_by": "ENTRYPOINT [\"/%s\"]" % entry,
                     "empty_layer": True}],
        "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}, separators=(",", ":")).encode()
    manifest = json.dumps({"schemaVersion": 2, "mediaType": DOCKER_MANIFEST,
                           "config": {"mediaType": DOCKER_CONFIG, "digest": sha(config), "size": len(config)},
                           "layers": [{"mediaType": DOCKER_LAYER, "digest": sha(layer_gz), "size": len(layer_gz)}]},
                          separators=(",", ":")).encode()
    return layer_gz, config, manifest


def truth(layer_gz, config, manifest):
    return json.dumps({"manifest": sha(manifest), "manifest_size": len(manifest), "config": sha(config),
                       "layer": sha(layer_gz), "layer_size": len(layer_gz), "media_type": DOCKER_MANIFEST})


def http(method, url, data, ctype):
    headers = {"Content-Type": ctype, "User-Agent": "docker/20.10.21 (setup)"}
    if os.environ.get("REG_AUTH"):      # user:password of the registry, from the environment of setup
        headers["Authorization"] = "Basic " + base64.b64encode(os.environ["REG_AUTH"].encode()).decode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=30, context=ssl._create_unverified_context()) as r:
        return r.status


mode = sys.argv[1]
if mode == "push":
    base, repo, tag, binary, entry = sys.argv[2:7]
    layer_gz, config, manifest = build(binary, entry)
    for blob in (layer_gz, config):
        assert http("POST", "%s/v2/%s/blobs/uploads/?digest=%s" % (base, repo, sha(blob)), blob,
                    "application/octet-stream") == 201
    assert http("PUT", "%s/v2/%s/manifests/%s" % (base, repo, tag), manifest, DOCKER_MANIFEST) == 201
    print(truth(layer_gz, config, manifest))
else:
    out, ref, binary, entry = sys.argv[2:6]
    layer_gz, config, manifest = build(binary, entry)
    index = json.dumps({"schemaVersion": 2, "manifests": [{
        "mediaType": DOCKER_MANIFEST, "digest": sha(manifest), "size": len(manifest),
        "annotations": {"io.containerd.image.name": ref,
                        "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
    with tarfile.open(out, "w") as t:
        def add(name, data):
            ti = tarfile.TarInfo(name)
            ti.size, ti.mtime = len(data), 1700000000
            t.addfile(ti, io.BytesIO(data))
        add("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
        add("index.json", index)
        for dg, data in ((sha(layer_gz), layer_gz), (sha(config), config), (sha(manifest), manifest)):
            add("blobs/sha256/" + dg.split(":")[1], data)
    print(truth(layer_gz, config, manifest))
PYEOF

echo "[setup] making the certificates: the CA of the company (self-signed; the machine's trust store does not have it) and the"
echo "[setup] certificate of the registry it signed (SAN = the registry name, so a client that trusts the CA is happy). A second CA"
echo "[setup] and a certificate of it for the same name are made as well: the oracle uses them to see that verification is on..."
PKI_TMP="$STATE_DIR/pki"; mkdir -p "$PKI_TMP"
mkpki() {   # $1 = prefix, $2 = CA common name
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$PKI_TMP/$1-ca.key" -out "$PKI_TMP/$1-ca.crt" -days 30 -subj "/CN=$2" >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -keyout "$PKI_TMP/$1-srv.key" -out "$PKI_TMP/$1-srv.csr" -subj "/CN=$REG_HOST" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$REG_HOST" > "$PKI_TMP/$1-ext.cnf"
    openssl x509 -req -in "$PKI_TMP/$1-srv.csr" -CA "$PKI_TMP/$1-ca.crt" -CAkey "$PKI_TMP/$1-ca.key" -CAcreateserial -out "$PKI_TMP/$1-srv.crt" -days 30 -extfile "$PKI_TMP/$1-ext.cnf" >/dev/null 2>&1
}
mkpki good "bench75817724 company CA" || { echo "[setup] ERROR: could not make the certificates"; exit 1; }
mkpki other "bench75817724 unrelated CA" || { echo "[setup] ERROR: could not make the certificates"; exit 1; }
sudo cp "$PKI_TMP/good-ca.crt" "$PKI_DIR/ca.crt"
sudo chmod 644 "$PKI_DIR/ca.crt"
sudo sha256sum "$PKI_DIR/ca.crt" | awk '{print $1}' > "$STATE_DIR/ca.sha256"
if openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$PKI_DIR/ca.crt" >/dev/null 2>&1; then
    echo "[setup] ERROR: the host's trust store already trusts the CA of the case"; exit 1
fi

echo "[setup] starting the private registry: HTTPS on 127.0.0.1:$REG_PORT with that certificate, anonymous pull, every request"
echo "[setup] logged with its User-Agent and TLS version. It is a FIXTURE (a registry API server holding the image)..."
sudo mkdir -p "$REG_DIR"
cat > "$STATE_DIR/registry.py" <<'PYEOF'
"""A minimal, read-write OCI/Docker distribution registry (HTTPS when REG_CERT/REG_KEY are set; Basic authentication).

Authentication: every request (also /v2/) needs "Authorization: Basic" credentials of an account in users.json
(argument 5); without them, or with a wrong password, the answer is 401 with a WWW-Authenticate: Basic challenge.
The log line ends with tls=<version|none> auth=none|bad:<user>|ok:<user>.

Rules: a repository name is a path of lowercase components (any depth, as in the distribution spec);
writes (blob uploads, manifest puts) are accepted for every repository (with an organisation prefix as
4th argument, only below it); blobs
are visible only in the repository they were pushed to (as in a real registry); a manifest is only
accepted when its config and layers are already in that repository. Every request is logged with its
status and User-Agent; the state (repositories, tags, manifests, blobs) is written to state.json.
"""
import base64
import hashlib
import hmac
import http.server
import json
import os
import re
import ssl
import sys
import threading
import urllib.parse
import uuid

root, port, logfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
CERT, KEY = os.environ.get("REG_CERT"), os.environ.get("REG_KEY")
org = sys.argv[4] if len(sys.argv) > 4 else ""
USERS = json.load(open(sys.argv[5])) if len(sys.argv) > 5 else None
BLOBS = os.path.join(root, "blobs")
os.makedirs(BLOBS, exist_ok=True)
LOG = open(logfile, "a", buffering=1)
LOCK = threading.Lock()
REPOS = {}      # name -> {"tags": {tag: digest}, "manifests": {digest: media type}, "blobs": set(digests)}
UPLOADS = {}    # uuid -> [repo, bytearray]
COMP = re.compile(r"^[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
TAG = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")
# a registry that is started again on the same directory serves what the earlier one held
try:
    for _n, _r in json.load(open(os.path.join(root, "state.json"))).items():
        REPOS[_n] = {"tags": _r["tags"], "manifests": _r["manifests"], "blobs": set(_r["blobs"])}
except FileNotFoundError:
    pass


def save_state():
    state = {n: {"tags": r["tags"], "manifests": r["manifests"], "blobs": sorted(r["blobs"])}
             for n, r in REPOS.items()}
    tmp = os.path.join(root, "state.json.tmp")
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, os.path.join(root, "state.json"))


def blob_path(d):
    return os.path.join(BLOBS, d.split(":")[1])


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    # ---- plumbing -------------------------------------------------------------------------
    def send_response(self, code, message=None):
        self._status = code
        super().send_response(code, message)

    def _body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            data = b""
            while True:
                size = int(self.rfile.readline().strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _reply(self, code, body=b"", ctype="application/json", headers=None, head=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Docker-Distribution-Api-Version", "registry/2.0")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body and not head:
            self.wfile.write(body)

    def _err(self, code, ecode, msg="", head=False):
        body = json.dumps({"errors": [{"code": ecode, "message": msg}]}).encode()
        self._reply(code, body, head=head)

    def _dispatch(self, method):
        self._status = 0
        self._note = ""
        self._who = ""
        try:
            self._route(method)
        finally:
            tls = self.connection.version() if isinstance(self.connection, ssl.SSLSocket) else "none"
            LOG.write("%s %s %s ua=%s tls=%s%s%s\n" % (method, self.path, self._status,
                                                       self.headers.get("User-Agent", ""), tls, self._note, self._who))

    def _authenticated(self):
        if USERS is None:
            return True
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic "):
            try:
                user, _, pw = base64.b64decode(h[6:]).decode().partition(":")
            except ValueError:
                user, pw = "?", None
            if pw is not None and user in USERS and hmac.compare_digest(USERS[user], pw):
                self._who = " auth=ok:%s" % user
                return True
            self._who = " auth=bad:%s" % user
        else:
            self._who = " auth=none"
        return False

    # ---- routing --------------------------------------------------------------------------
    def _route(self, m):
        head = m == "HEAD"
        if not self._authenticated():
            self._body()
            body = json.dumps({"errors": [{"code": "UNAUTHORIZED", "message": "authentication required"}]}).encode()
            return self._reply(401, body, headers={"WWW-Authenticate": 'Basic realm="bench registry"'}, head=head)
        path, _, query = self.path.partition("?")
        params = {k: urllib.parse.unquote(v) for k, v in (p.split("=", 1) for p in query.split("&") if "=" in p)}
        if path in ("/v2/", "/v2"):
            return self._reply(200, b"{}", head=head)
        if path == "/v2/_catalog":
            return self._reply(200, json.dumps({"repositories": sorted(REPOS)}).encode(), head=head)
        mt = re.match(r"^/v2/(.+)/(manifests|blobs|tags)/(.*)$", path)
        if not mt:
            return self._err(404, "UNSUPPORTED", "unknown endpoint", head)
        name, kind, rest = mt.groups()
        if not all(COMP.match(c) for c in name.split("/")):
            self._body()
            return self._err(400, "NAME_INVALID", "invalid repository name", head)
        write = m in ("POST", "PUT", "PATCH")
        if write and org and not name.startswith(org + "/"):
            self._body()
            return self._err(403, "DENIED", "this registry only accepts repositories below %s/" % org, head)
        with LOCK:
            if kind == "blobs" and (rest == "uploads/" or rest.startswith("uploads/")):
                return self._uploads(m, name, rest[len("uploads/"):], params)
            if kind == "blobs":
                return self._blob(name, rest, head)
            if kind == "manifests":
                return self._manifest(m, name, rest, head)
            if kind == "tags" and rest == "list":
                r = REPOS.get(name)
                if not r:
                    return self._err(404, "NAME_UNKNOWN", "repository name not known to registry", head)
                return self._reply(200, json.dumps({"name": name, "tags": sorted(r["tags"])}).encode(), head=head)
        self._err(404, "UNSUPPORTED", "unknown endpoint", head)

    def _uploads(self, m, name, uid, params):
        repo = REPOS.setdefault(name, {"tags": {}, "manifests": {}, "blobs": set()})
        if m == "POST":
            body = self._body()
            u = str(uuid.uuid4())
            UPLOADS[u] = [name, bytearray(body)]
            if "digest" in params:
                return self._finish_upload(name, u, params["digest"])
            return self._reply(202, b"", headers={"Location": "/v2/%s/blobs/uploads/%s" % (name, u),
                                                  "Docker-Upload-UUID": u, "Range": "0-0"})
        up = UPLOADS.get(uid)
        if not up or up[0] != name:
            self._body()
            return self._err(404, "BLOB_UPLOAD_UNKNOWN", "upload unknown")
        if m == "PATCH":
            up[1].extend(self._body())
            return self._reply(202, b"", headers={"Location": "/v2/%s/blobs/uploads/%s" % (name, uid),
                                                  "Docker-Upload-UUID": uid,
                                                  "Range": "0-%d" % max(len(up[1]) - 1, 0)})
        if m == "PUT":
            up[1].extend(self._body())
            return self._finish_upload(name, uid, params.get("digest", ""))
        self._err(405, "UNSUPPORTED", "method not allowed")

    def _finish_upload(self, name, uid, digest):
        data = bytes(UPLOADS.pop(uid)[1])
        if not DIGEST.match(digest) or "sha256:" + hashlib.sha256(data).hexdigest() != digest:
            return self._err(400, "DIGEST_INVALID", "provided digest did not match uploaded content")
        with open(blob_path(digest), "wb") as f:
            f.write(data)
        REPOS[name]["blobs"].add(digest)
        save_state()
        self._note = " digest=%s" % digest
        self._reply(201, b"", headers={"Location": "/v2/%s/blobs/%s" % (name, digest),
                                       "Docker-Content-Digest": digest})

    def _blob(self, name, digest, head):
        r = REPOS.get(name)
        if not r:
            return self._err(404, "NAME_UNKNOWN", "repository name not known to registry", head)
        if digest not in r["blobs"]:
            return self._err(404, "BLOB_UNKNOWN", "blob unknown to registry", head)
        data = open(blob_path(digest), "rb").read()
        self._reply(200, data, "application/octet-stream", {"Docker-Content-Digest": digest}, head)

    def _manifest(self, m, name, ref, head):
        r = REPOS.get(name)
        if m == "PUT":
            body = self._body()
            digest = "sha256:" + hashlib.sha256(body).hexdigest()
            self._note = " digest=%s" % digest
            if DIGEST.match(ref) and ref != digest:
                return self._err(400, "DIGEST_INVALID", "manifest digest mismatch")
            if not DIGEST.match(ref) and not TAG.match(ref):
                return self._err(400, "TAG_INVALID", "invalid tag")
            try:
                man = json.loads(body)
                need = [man["config"]["digest"]] + [l["digest"] for l in man.get("layers", [])]
            except (ValueError, KeyError, TypeError):
                return self._err(400, "MANIFEST_INVALID", "manifest invalid")
            repo = REPOS.setdefault(name, {"tags": {}, "manifests": {}, "blobs": set()})
            missing = [d for d in need if d not in repo["blobs"]]
            if missing:
                return self._err(400, "MANIFEST_BLOB_UNKNOWN", "blob unknown to registry: %s" % missing[0])
            with open(blob_path(digest), "wb") as f:
                f.write(body)
            repo["blobs"].add(digest)
            repo["manifests"][digest] = self.headers.get("Content-Type", "application/vnd.oci.image.manifest.v1+json")
            if not DIGEST.match(ref):
                repo["tags"][ref] = digest
            save_state()
            return self._reply(201, b"", headers={"Location": "/v2/%s/manifests/%s" % (name, digest),
                                                  "Docker-Content-Digest": digest})
        if not r:
            return self._err(404, "NAME_UNKNOWN", "repository name not known to registry", head)
        digest = ref if DIGEST.match(ref) else r["tags"].get(ref)
        if not digest or digest not in r["manifests"]:
            return self._err(404, "MANIFEST_UNKNOWN", "manifest unknown", head)
        self._note = " digest=%s" % digest
        self._reply(200, open(blob_path(digest), "rb").read(), r["manifests"][digest],
                    {"Docker-Content-Digest": digest}, head)

    def do_GET(self):
        self._dispatch("GET")

    def do_HEAD(self):
        self._dispatch("HEAD")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_PATCH(self):
        self._dispatch("PATCH")


class S(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        pass            # a client that refuses the certificate leaves a failed handshake: not an error of the fixture


save_state()
srv = S(("127.0.0.1", port), H)
if CERT:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
srv.serve_forever()
PYEOF
sudo cp "$STATE_DIR/registry.py" "$REG_DIR/registry.py"
sudo cp "$PKI_TMP/good-srv.crt" "$REG_DIR/srv.pem"
sudo cp "$PKI_TMP/good-srv.key" "$REG_DIR/srv.key"
sudo cp "$PKI_TMP/other-srv.crt" "$REG_DIR/other.pem"
sudo cp "$PKI_TMP/other-srv.key" "$REG_DIR/other.key"
sudo chmod 600 "$REG_DIR/srv.key" "$REG_DIR/other.key"
rm -rf "$PKI_TMP"      # the keys of both CAs are discarded
sudo touch "$REG_DIR/requests.log"
start_daemon "$REG_DIR/registry.pid" "$REG_DIR/registry.out" \
    env REG_CERT="$REG_DIR/srv.pem" REG_KEY="$REG_DIR/srv.key" python3 "$REG_DIR/registry.py" "$REG_DIR" "$REG_PORT" "$REG_DIR/requests.log"
for _ in $(seq 1 40); do
    curl -sk --max-time 2 "https://127.0.0.1:$REG_PORT/v2/" >/dev/null 2>&1 && break
    sleep 0.25
done
curl -sk --max-time 2 "https://127.0.0.1:$REG_PORT/v2/" >/dev/null \
    || { echo "[setup] ERROR: the registry did not come up"; sudo tail -5 "$REG_DIR/registry.out" 2>/dev/null; exit 1; }
echo "  -> registry up on 127.0.0.1:$REG_PORT (HTTPS)"

echo "[setup] caching $REPO:$TAG in it (the build inputs of the image stay out of the machine)..."
python3 "$STATE_DIR/mkimg.py" push "https://127.0.0.1:$REG_PORT" "$REPO" "$TAG" "$STATE_DIR/app" app > "$STATE_DIR/image.truth" \
    || { echo "[setup] ERROR: could not push the image to the registry"; exit 1; }
cat "$STATE_DIR/image.truth"
MDIGEST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/image.truth")
echo "$MDIGEST" > "$STATE_DIR/manifest.digest"
sudo mkdir -p "$K3S_DATA/agent/images"
sudo "$(command -v python3)" "$STATE_DIR/mkimg.py" tar "$K3S_DATA/agent/images/pause.tar" "$PAUSE_REF" "$STATE_DIR/pause" pause >/dev/null
echo "  -> $REG_HOST:$REG_PORT/$REPO:$TAG = $MDIGEST"

echo "[setup] starting the egress proxy of this machine (HTTP proxy on 127.0.0.1:$HUB_PORT): the only way out for k3s and its"
echo "[setup] containerd. It resolves and reaches the private registry by name (HTTPS tunnels) and refuses (403) everything"
echo "[setup] else; every request is logged..."
sudo mkdir -p "$HUB_DIR"
cat > "$STATE_DIR/hubgate.py" <<'PYEOF'
"""Egress proxy of the case. Names it knows (host:port=target) are reached: CONNECT is tunnelled, plain HTTP requests in
absolute form (what an HTTP client sends to a proxy) are forwarded. Everything else is refused with 403. Every request is
logged ("CONNECT host:port ALLOW|DENY", "METHOD url ALLOW|DENY"). the runtime is started with HTTP(S)_PROXY pointing here,
so the registry name needs no DNS entry on the machine and nothing reaches the Internet."""
import http.client
import http.server
import socket
import sys
import threading
import urllib.parse

port, logfile = int(sys.argv[1]), sys.argv[2]
ROUTES = dict(a.split("=", 1) for a in sys.argv[3:])        # "host:port=127.0.0.1:port"
LOG = open(logfile, "a", buffering=1)
HOP = {"connection", "proxy-connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
       "proxy-authorization", "proxy-authenticate"}


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def deny(self):
        LOG.write("%s %s DENY\n" % (self.command, self.path))
        body = b"refused by the egress proxy of this machine\n"
        self.send_response(403, "Forbidden")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_CONNECT(self):
        target = ROUTES.get(self.path)
        if not target:
            return self.deny()
        host, _, p = target.rpartition(":")
        try:
            up = socket.create_connection((host, int(p)), timeout=10)
        except OSError:
            return self.deny()
        LOG.write("CONNECT %s ALLOW\n" % self.path)
        self.send_response(200, "Connection established")
        self.end_headers()
        self.wfile.flush()
        t = threading.Thread(target=pipe, args=(up, self.connection), daemon=True)
        t.start()
        pipe(self.connection, up)
        t.join(5)
        self.close_connection = True

    def forward(self):
        u = urllib.parse.urlsplit(self.path)
        target = ROUTES.get("%s:%s" % (u.hostname, u.port or 80)) if u.scheme == "http" else None
        if not target:
            n = int(self.headers.get("Content-Length") or 0)
            if n:
                self.rfile.read(n)
            return self.deny()
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        host, _, p = target.rpartition(":")
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        headers["Host"] = "%s:%s" % (u.hostname, u.port or 80)
        try:
            c = http.client.HTTPConnection(host, int(p), timeout=30)
            c.request(self.command, (u.path or "/") + ("?" + u.query if u.query else ""), body, headers)
            r = c.getresponse()
            data = r.read()
        except OSError:
            return self.deny()
        LOG.write("%s %s ALLOW\n" % (self.command, self.path))
        self.send_response(r.status, r.reason)
        for k, v in r.getheaders():
            if k.lower() not in HOP and k.lower() != "content-length":
                self.send_header(k, v)
        # a HEAD answer carries the length of the body it does not send
        self.send_header("Content-Length", r.getheader("Content-Length") or str(len(data)) if self.command == "HEAD" else str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = forward


class S(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


S(("127.0.0.1", port), H).serve_forever()
PYEOF
sudo cp "$STATE_DIR/hubgate.py" "$HUB_DIR/hubgate.py"
sudo touch "$HUB_DIR/requests.log"
start_daemon "$HUB_DIR/hubgate.pid" "$HUB_DIR/hubgate.out" \
    python3 "$HUB_DIR/hubgate.py" "$HUB_PORT" "$HUB_DIR/requests.log" "$REG_HOST:$REG_PORT=127.0.0.1:$REG_PORT"
for _ in $(seq 1 40); do
    curl -s --max-time 2 -o /dev/null -x "http://127.0.0.1:$HUB_PORT" "http://proxy-probe.invalid/" 2>/dev/null || true
    [ "$(sudo wc -l < "$HUB_DIR/requests.log")" != "0" ] && break
    sleep 0.25
done
[ "$(sudo wc -l < "$HUB_DIR/requests.log")" != "0" ] || { echo "[setup] ERROR: the egress proxy did not come up"; exit 1; }
sudo sh -c ': > "$1"' _ "$HUB_DIR/requests.log"
echo "  -> egress proxy up on 127.0.0.1:$HUB_PORT"

echo "[setup] writing the k3s configuration $K3S_CONFIG (the standard place; the options of k3s without the"
echo "[setup] leading dashes) and the script that starts and stops k3s on this machine..."
sudo mkdir -p /etc/rancher/k3s
cat <<CEOF | sudo tee "$K3S_CONFIG" >/dev/null
# k3s configuration of this machine
https-listen-port: 16443
node-name: $NODE
pause-image: $PAUSE_REF
# a small single node: no add-ons, no network plugin, nothing that touches the host's network
disable:
  - traefik
  - servicelb
  - metrics-server
  - coredns
  - local-storage
disable-cloud-controller: true
disable-helm-controller: true
disable-network-policy: true
disable-kube-proxy: true
flannel-backend: none
kubelet-arg:
  - root-dir=$LIB_BASE/kubelet
  - cgroups-per-qos=false
  - enforce-node-allocatable=
  - make-iptables-util-chains=false
CEOF
cat <<CEOF | sudo tee "$CTL_DIR/k3sctl" >/dev/null
#!/bin/bash
# how k3s is started and stopped on this machine: k3sctl start|stop|restart|status
# (k3s reads its options from $K3S_CONFIG and writes the configuration of its embedded containerd, \$DATA/agent/etc/containerd/config.toml, at every start)
# This machine reaches anything only through its egress proxy, so k3s (and the containerd it starts) runs with the proxy variables.
PIDF="$RUN_BASE/k3s.pid"
GATE="http://127.0.0.1:$HUB_PORT"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "k3s is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec env HTTP_PROXY="\$4" HTTPS_PROXY="\$4" http_proxy="\$4" https_proxy="\$4" NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost "\$2" server >>"\$3" 2>&1 </dev/null' _ "\$PIDF" "$K3S_BIN" "$RUN_BASE/k3s.log" "\$GATE" </dev/null >/dev/null 2>&1
    echo "k3s started"
}
do_stop() {
    alive || { echo "k3s is not running"; return 0; }
    kill -TERM "\$(cat "\$PIDF")"
    for _ in \$(seq 1 60); do alive || break; sleep 1; done
    alive && kill -KILL "\$(cat "\$PIDF")"
    echo "k3s stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid \$(cat "\$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: k3sctl start|stop|restart|status"; exit 2 ;;
esac
CEOF
sudo chmod 755 "$CTL_DIR/k3sctl"
sudo sha256sum "$CTL_DIR/k3sctl" | awk '{print $1}' > "$STATE_DIR/k3sctl.sha"

echo "[setup] starting k3s. Waiting for the node $NODE to be Ready..."
sudo "$CTL_DIR/k3sctl" start >/dev/null
kube() { sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$K3S_BIN" kubectl "$@"; }
READY=""
for _ in $(seq 1 90); do
    READY=$(kube get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ "$READY" = "True" ] && break
    sleep 2
done
if [ "$READY" != "True" ]; then
    echo "[setup] ERROR: the node $NODE did not become Ready; last log lines of k3s:"
    sudo tail -5 "$RUN_BASE/k3s.log" 2>/dev/null | cut -c1-200
    exit 1
fi
echo "  -> node $NODE Ready, container runtime $(kube get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')"

echo "[setup] recording the identity of the daemons (pid + start time)..."
P=$(sudo cat "$RUN_BASE/k3s.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/k3s.id"
P=$(sudo cat "$REG_DIR/registry.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/registry.id"
P=$(sudo cat "$HUB_DIR/hubgate.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/hubgate.id"
# what the registry holds now, to prove later that nobody changed it; the trust store of this host as it is now
sudo cp "$REG_DIR/state.json" "$STATE_DIR/registry.state0"
{ sha256sum /etc/ssl/certs/ca-certificates.crt 2>/dev/null | awk '{print $1}'; ls -1 /usr/local/share/ca-certificates 2>/dev/null; } > "$STATE_DIR/hosttrust.0"

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/pause" "$STATE_DIR/pause.c" "$STATE_DIR/mkimg.py" \
    "$STATE_DIR/registry.py" "$STATE_DIR/hubgate.py"

echo "[setup] done. k3s runs with its embedded containerd; the registry $REG_HOST:$REG_PORT is HTTPS with the certificate of the"
echo "[setup] company CA ($PKI_DIR/ca.crt), which containerd does not know."
