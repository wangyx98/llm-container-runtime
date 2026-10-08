#!/bin/bash
set -e

CASE_ID="bench73415766"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files and logs of containerd and of the two fixtures
LIB_BASE="/var/lib/$CASE_ID"          # containerd root, control scripts (not in /run: it is mounted noexec on many hosts)
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
HOST_A="pvt-a.registry.test"          # the private registry of the question (HTTPS, a certificate of an unknown CA)
REG_A_DIR="$RUN_BASE/regA"
REG_A_PORT=5028
HOST_B="pvt-b.registry.test"          # another private registry with the same problem (another unknown CA)
REG_B_DIR="$RUN_BASE/regB"
REG_B_PORT=5038
HUB_DIR="$RUN_BASE/proxy"             # the corporate egress proxy: resolves and reaches the two registries, refuses the rest
HUB_PORT=18096
REPO="team/app"
TAG="1.0"
PAUSE_REF="bench73415766.local/pause:1"   # sandbox image name in the config (no pod is run by this case)

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking containerd, ctr, runc, curl and python3 are installed (the runtime under test)..."
for b in containerd ctr runc curl python3 openssl; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking that ports $REG_A_PORT, $REG_B_PORT and $HUB_PORT are free..."
for p in $REG_A_PORT $REG_B_PORT $HUB_PORT; do
    if curl -sk --max-time 2 -o /dev/null "https://127.0.0.1:$p/" 2>/dev/null || curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null; then
        echo "[setup] ERROR: something already listens on 127.0.0.1:$p"; exit 1
    fi
done

echo "[setup] ensuring crictl is installed (the CRI client; same pinned version as the CRI-O cases)..."
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
crictl --version

echo "[setup] making sure gcc is available (gcc: two tiny static programs, the only files of the two images,"
echo "[setup] so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

sudo mkdir -p "$LIB_BASE"

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR"
cd "$WORK_DIR"

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of
# the daemon itself (exec keeps the pid); setsid + all three fds redirected so it outlives this
# script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] building the two images offline, in DOCKER format (what docker push sends): one static program each"
echo "[setup] that prints a marker line with its own random token and its arguments, then exits..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>

int main(int argc, char **argv) {
    printf("bench73415766-ok token=" TOKEN " args=");
    for (int i = 1; i < argc; i++) printf("%s%s", i > 1 ? "," : "", argv[i]);
    printf("\n");
    return 0;
}
CEOF
for w in a b; do
    T="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
    gcc -static -Os -s -w -DTOKEN="\"$T\"" -o "$STATE_DIR/app-$w" "$STATE_DIR/app.c"
    sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$T" "$STATE_DIR/token.$w"
done
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py push BASEURL REPO TAG BINARY ENTRY  : build a Docker image (one layer with BINARY as /ENTRY) and
push it to the registry with the plain distribution API (what `docker push` does)
   mkimg.py tar OUT REF BINARY ENTRY            : build the same into an OCI archive (for ctr images import)
Prints the digests as JSON."""
import gzip
import hashlib
import io
import json
import os
import ssl
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


CTX = ssl.create_default_context()      # the setup talks to its own fixtures, whose certificates have an unknown CA
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def http(method, url, data, ctype):
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": ctype,
                                                                         "User-Agent": "docker/20.10.21 (setup)"})
    with urllib.request.urlopen(req, timeout=30, context=CTX) as r:
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

echo "[setup] making the certificates of the two private registries: each signed by a CA of its own, that nobody trusts"
echo "[setup] (the CA keys are discarded; the SAN is the registry name, so the ONLY problem is the unknown authority)..."
for w in a b; do
    d="$STATE_DIR/pki-$w"; mkdir -p "$d"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/ca.key" -out "$d/ca.pem" -days 30 -subj "/CN=bench73415766 private CA $w" >/dev/null 2>&1
    if [ "$w" = a ]; then NAME="$HOST_A"; else NAME="$HOST_B"; fi
    openssl req -newkey rsa:2048 -nodes -keyout "$d/srv.key" -out "$d/srv.csr" -subj "/CN=$NAME" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$NAME" > "$d/ext.cnf"
    openssl x509 -req -in "$d/srv.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial -out "$d/srv.pem" -days 30 -extfile "$d/ext.cnf" >/dev/null 2>&1 \
        || { echo "[setup] ERROR: could not make the certificate of registry $w"; exit 1; }
    rm -f "$d/ca.key" "$d/srv.csr" "$d/ca.srl" "$d/ext.cnf"
done

cat > "$STATE_DIR/registry.py" <<'PYEOF'
"""A minimal, read-write OCI/Docker distribution registry (HTTP, or HTTPS when REG_CERT/REG_KEY are set; no auth).

Rules: a repository name is a path of lowercase components (any depth, as in the distribution spec);
writes (blob uploads, manifest puts) are accepted for every repository (with an organisation prefix as
4th argument, only below it); blobs
are visible only in the repository they were pushed to (as in a real registry); a manifest is only
accepted when its config and layers are already in that repository. Every request is logged with its
status and User-Agent; the state (repositories, tags, manifests, blobs) is written to state.json.
"""
import hashlib
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
org = ""
CERT, KEY = os.environ.get("REG_CERT", ""), os.environ.get("REG_KEY", "")
BLOBS = os.path.join(root, "blobs")
os.makedirs(BLOBS, exist_ok=True)
LOG = open(logfile, "a", buffering=1)
LOCK = threading.Lock()
REPOS = {}      # name -> {"tags": {tag: digest}, "manifests": {digest: media type}, "blobs": set(digests)}
UPLOADS = {}    # uuid -> [repo, bytearray]
COMP = re.compile(r"^[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
TAG = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")


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
        try:
            self._route(method)
        finally:
            tls = self.connection.version() if isinstance(self.connection, ssl.SSLSocket) else "none"
            LOG.write("%s %s %s ua=%s tls=%s%s\n" % (method, self.path, self._status,
                                                     self.headers.get("User-Agent", ""), tls, self._note))

    # ---- routing --------------------------------------------------------------------------
    def _route(self, m):
        head = m == "HEAD"
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
start_registry() {   # $1 = dir, $2 = port, $3 = pki dir
    sudo mkdir -p "$1"
    sudo cp "$STATE_DIR/registry.py" "$1/registry.py"
    sudo cp "$3/srv.pem" "$1/srv.pem"
    sudo cp "$3/srv.key" "$1/srv.key"
    sudo chmod 600 "$1/srv.key"
    sudo touch "$1/requests.log"
    start_daemon "$1/registry.pid" "$1/registry.out" \
        env REG_CERT="$1/srv.pem" REG_KEY="$1/srv.key" python3 "$1/registry.py" "$1" "$2" "$1/requests.log"
    for _ in $(seq 1 40); do
        curl -sfk --max-time 2 "https://127.0.0.1:$2/v2/" >/dev/null 2>&1 && break
        sleep 0.25
    done
    curl -sfk --max-time 2 "https://127.0.0.1:$2/v2/" >/dev/null \
        || { echo "[setup] ERROR: the registry on port $2 did not come up"; sudo tail -5 "$1/registry.out" 2>/dev/null; exit 1; }
}
echo "[setup] starting the two private registries (HTTPS, anonymous pull, every request logged with its User-Agent and"
echo "[setup] TLS version); they are FIXTURES (registry API servers)..."
start_registry "$REG_A_DIR" "$REG_A_PORT" "$STATE_DIR/pki-a"
start_registry "$REG_B_DIR" "$REG_B_PORT" "$STATE_DIR/pki-b"
echo "  -> registries up on 127.0.0.1:$REG_A_PORT and 127.0.0.1:$REG_B_PORT"

echo "[setup] pushing $REPO:$TAG to each (a different image in each)..."
for p in "a:$REG_A_PORT" "b:$REG_B_PORT"; do
    w=${p%%:*}; port=${p#*:}
    python3 "$STATE_DIR/mkimg.py" push "https://127.0.0.1:$port" "$REPO" "$TAG" "$STATE_DIR/app-$w" app > "$STATE_DIR/$w.truth" \
        || { echo "[setup] ERROR: could not push the image to the registry $w"; exit 1; }
    echo "  -> port $port: $REPO:$TAG = $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/$w.truth")"
done
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/a.truth")" != \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/b.truth")" ] \
    || { echo "[setup] ERROR: the two images are the same"; exit 1; }
# the certificates' public parts stay with the fixtures only; the setup keeps nothing it does not need
rm -rf "$STATE_DIR"/pki-a "$STATE_DIR"/pki-b

echo "[setup] starting the corporate egress proxy of this machine (HTTP proxy on 127.0.0.1:$HUB_PORT): the only way out for"
echo "[setup] containerd. It resolves and reaches the two private registries by name and refuses (403) everything else;"
echo "[setup] it logs every CONNECT..."
sudo mkdir -p "$HUB_DIR"
cat > "$STATE_DIR/hubgate.py" <<'PYEOF'
"""Egress proxy of the case: an HTTP proxy for HTTPS (CONNECT). The names it knows (the private registries) are
tunnelled to the fixture behind them, everything else is refused with 403. Every CONNECT is logged
("CONNECT host:port ALLOW|DENY"). containerd is started with HTTP(S)_PROXY pointing here, so the names need no DNS
entry on the machine and nothing reaches the Internet."""
import http.server
import socket
import sys
import threading

port, logfile = int(sys.argv[1]), sys.argv[2]
ROUTES = dict(a.split("=", 1) for a in sys.argv[3:])        # "host:port=127.0.0.1:port"
LOG = open(logfile, "a", buffering=1)


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

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = deny


class S(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


S(("127.0.0.1", port), H).serve_forever()
PYEOF
sudo cp "$STATE_DIR/hubgate.py" "$HUB_DIR/hubgate.py"
sudo touch "$HUB_DIR/requests.log"
start_daemon "$HUB_DIR/hubgate.pid" "$HUB_DIR/hubgate.out" \
    python3 "$HUB_DIR/hubgate.py" "$HUB_PORT" "$HUB_DIR/requests.log" \
        "$HOST_A:$REG_A_PORT=127.0.0.1:$REG_A_PORT" "$HOST_B:$REG_B_PORT=127.0.0.1:$REG_B_PORT"
for _ in $(seq 1 40); do
    curl -s --max-time 2 -o /dev/null -x "http://127.0.0.1:$HUB_PORT" "http://proxy-probe.invalid/" 2>/dev/null || true
    [ "$(sudo wc -l < "$HUB_DIR/requests.log")" != "0" ] && break
    sleep 0.25
done
[ "$(sudo wc -l < "$HUB_DIR/requests.log")" != "0" ] || { echo "[setup] ERROR: the egress proxy did not come up"; exit 1; }
sudo sh -c ': > "$1"' _ "$HUB_DIR/requests.log"
echo "  -> egress proxy up on 127.0.0.1:$HUB_PORT"

echo "[setup] starting the pre-installed containerd (the runtime of this machine: own socket, root and state;"
echo "[setup] containerd's own default config for the installed version, moved into that root/state, NRI off,"
echo "[setup] and the TLS configuration of the question, written with a typo (the plugin table is named 'plugin', not"
echo "[setup] 'plugins'), which containerd ignores)..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock, cni, pause, host = sys.argv[1:7]
section = ""
registry = None          # the CRI registry table of this version (the legacy mirrors table hangs below it)
mirrors_seen = False
out = []
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}'\n"
    elif section == "grpc" and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif section == "ttrpc" and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        # do not require CAP_SYS_RESOURCE (absent in unprivileged or nested environments)
        line = f"{indent}restrict_oom_score_adj = true\n"
    elif section.endswith(".cni") and k == "bin_dirs":
        line = f"{indent}bin_dirs = ['{cni}/bin']\n"
    elif section.endswith(".cni") and k == "bin_dir" and not re.search(r"=\s*(''|\"\")\s*$", line):
        # containerd 1.x: bin_dir; 2.x has bin_dirs (and an empty bin_dir, which must stay empty)
        line = f"{indent}bin_dir = '{cni}/bin'\n"
    elif section.endswith(".cni") and k == "conf_dir":
        line = f"{indent}conf_dir = '{cni}/net.d'\n"
    elif section.endswith(".registry") and "cri" in section and k == "config_path":
        # the initial state has NO registry configuration for the CRI, whatever this version's default is
        line = f"{indent}config_path = ''\n"
    elif "pinned_images" in section and k == "sandbox":
        line = f"{indent}sandbox = '{pause}'\n"
    elif k == "sandbox_image":
        line = f"{indent}sandbox_image = '{pause}'\n"
    out.append(line)
# the configuration of the question: skip the TLS verification of the registry, in a table that is not a plugin's
out.append('\n[plugin."io.containerd.grpc.v1.cri".registry.configs."%s".tls]\n    insecure_skip_verify = true\n' % host)
sys.stdout.write("".join(out))
PYEOF
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" "$HOST_A:$REG_A_PORT" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
grep -q "insecure_skip_verify" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not write the TLS block in the containerd config"; exit 1; }
grep -q "$PAUSE_REF" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
cat <<CEOF | sudo tee "$CTL_DIR/containerdctl" >/dev/null
#!/bin/bash
# how this machine's containerd is started and stopped: containerdctl start|stop|restart|status
PIDF="$RUN_BASE/containerd.pid"
# (this machine reaches anything only through its egress proxy, so containerd runs with the proxy variables)
GATE="http://127.0.0.1:$HUB_PORT"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "containerd is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec env HTTP_PROXY="\$4" HTTPS_PROXY="\$4" http_proxy="\$4" https_proxy="\$4" NO_PROXY= no_proxy= containerd --config "\$2" >"\$3" 2>&1 </dev/null' _ "\$PIDF" "$RUN_BASE/config.toml" "$RUN_BASE/containerd.log" "\$GATE" </dev/null >/dev/null 2>&1
    echo "containerd started"
}
do_stop() {
    alive || { echo "containerd is not running"; return 0; }
    kill -TERM "\$(cat "\$PIDF")"
    for _ in \$(seq 1 40); do alive || break; sleep 0.5; done
    alive && kill -KILL "\$(cat "\$PIDF")"
    echo "containerd stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid \$(cat "\$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: containerdctl start|stop|restart|status"; exit 2 ;;
esac
CEOF
sudo chmod 755 "$CTL_DIR/containerdctl"
sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}' > "$STATE_DIR/containerdctl.sha"
sudo "$CTL_DIR/containerdctl" start >/dev/null
for _ in $(seq 1 60); do
    [ -S "$CTD_SOCK" ] && $CTR version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $CTR version >/dev/null 2>&1; then
    echo "[setup] ERROR: containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> containerd up on $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 60s)
"${CRI[@]}" version >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI of containerd does not answer"; exit 1; }
echo "  -> CRI answers"

echo "[setup] recording the identity of the daemons (pid + start time)..."
for d in containerd; do
    P=$(cat "$RUN_BASE/$d.pid")
    echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/$d.id"
done
P=$(cat "$HUB_DIR/hubgate.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/hubgate.id"
for w in a b; do
    d="$RUN_BASE/reg${w^^}"
    P=$(cat "$d/registry.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/registry-$w.id"
    cp "$d/state.json" "$STATE_DIR/registry-$w.state0"
done

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/app-a" "$STATE_DIR/app-b" "$STATE_DIR/app.c" "$STATE_DIR/mkimg.py" "$STATE_DIR/patch_config.py" "$STATE_DIR/registry.py" "$STATE_DIR/hubgate.py"

echo "[setup] done. Two private HTTPS registries ($HOST_A:$REG_A_PORT, $HOST_B:$REG_B_PORT) hold $REPO:$TAG with a"
echo "[setup] certificate of an unknown CA each; containerd's TLS configuration for $REG_A_PORT is misspelt and has no effect."
