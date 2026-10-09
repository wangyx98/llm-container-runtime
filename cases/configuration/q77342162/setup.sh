#!/bin/bash
set -e

CASE_ID="bench77342162"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files and logs of containerd and of the two fixtures
LIB_BASE="/var/lib/$CASE_ID"          # containerd root, control scripts (not in /run: it is mounted noexec on many hosts)
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/harbor"            # the Harbor-style registry fixture: blobs, state.json, users.json, requests.log (root-owned)
REG_PORT=8083                         # plain HTTP
REG_HOST="harbor.bench77342162.test"  # its name: it resolves through the egress proxy only (no /etc/hosts entry)
REG_USER="admin"                      # the account that pushed the cached image (a pull needs no account)
HUB_DIR="$RUN_BASE/proxy"             # the egress proxy: reaches Harbor by name, refuses (and logs) the rest
HUB_PORT=18098
PROJECT="kubernetes-cache"            # the proxy cache project of Harbor (public)
UPSTREAM="registry.k8s.io"            # the registry that project caches
IMG_NAME="kube-proxy"
TAG="v1.26.5"
HARBOR_REPO="$PROJECT/$IMG_NAME"      # how Harbor names the cached repository
EXT_REF="$UPSTREAM/$IMG_NAME:$TAG"    # the reference the cluster uses (the original, external one)
BAD_ENDPOINT="http://$REG_HOST:$REG_PORT/$PROJECT"   # the endpoint of the question: Harbor's host plus the project
PAUSE_REF="bench77342162.local/pause:1"   # sandbox ("pause") image, built here: no download at run time

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CERTS_DIR="/etc/containerd/certs.d"

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
for b in containerd ctr runc curl python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking this host's containerd has no registry configuration for $UPSTREAM or Harbor (the case manages those"
echo "[setup] entries), and that ports $REG_PORT and $HUB_PORT are free..."
for h in "$UPSTREAM" "$REG_HOST:$REG_PORT" "$REG_HOST"; do
    [ -e "$CERTS_DIR/$h" ] || continue
    if sudo grep -rqE "$REG_HOST|$UPSTREAM" "$CERTS_DIR/$h" 2>/dev/null || [ -z "$(sudo find "$CERTS_DIR/$h" -type f 2>/dev/null)" ]; then
        echo "[setup] $CERTS_DIR/$h is a leftover of this case (it names $REG_HOST or $UPSTREAM, or is empty): removing it"
        sudo rm -rf --one-file-system "$CERTS_DIR/$h"
    else
        echo "[setup] ERROR: $CERTS_DIR/$h exists and is not a leftover of this case; its content:"
        sudo find "$CERTS_DIR/$h" -type f -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \; 2>/dev/null | head -20
        exit 1
    fi
done
for p in $REG_PORT $HUB_PORT; do
    if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$p/" 2>/dev/null; then
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

echo "[setup] recording what $CERTS_DIR holds now (cleanup removes only what a solution adds)..."
sudo mkdir -p "$LIB_BASE"
if [ -d "$CERTS_DIR" ]; then
    ls -1 "$CERTS_DIR" | sudo tee "$LIB_BASE/certs.orig" >/dev/null
else
    sudo touch "$LIB_BASE/certs.absent"
fi
[ -d /etc/containerd ] || sudo touch "$LIB_BASE/etc_containerd.absent"

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

echo "[setup] building the two images offline, in DOCKER format (what docker push sends): the cached image, one static"
echo "[setup] program that prints a line with a per-run random token every 5 seconds and never exits, and the"
echo "[setup] sandbox image of the pods (a static program that only waits)..."
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    for (;;) {
        puts("bench77342162-kube-proxy-ok token=" TOKEN);
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

echo "[setup] starting the Harbor-style registry: plain HTTP on 127.0.0.1:$REG_PORT. It speaks Harbor's API as a pulling client sees it:"
echo "[setup] repositories are <project>/<repository> (a name without a project is refused with 400), Bearer-token authentication"
echo "[setup] through /service/token (anonymous tokens for the public project $PROJECT), every request logged with its full path and"
echo "[setup] User-Agent. It is a FIXTURE (a stand-in server, not the Harbor product)..."
sudo mkdir -p "$REG_DIR"
cat > "$STATE_DIR/registry.py" <<'PYEOF'
"""A minimal, read-write OCI/Docker distribution registry (HTTPS when REG_CERT/REG_KEY are set; Basic authentication).

Harbor mode (REG_HARBOR=<public projects, comma separated>): the API of a Harbor registry, as far as a pulling client sees it.
Repositories are <project>/<repository>: a name without a project is refused with 400 (NAME_INVALID), an unknown project is
404, the root of the host and every path outside /v2 and /service/token are 404. /v2/ and every repository endpoint need
a Bearer token: without one the answer is 401 with WWW-Authenticate: Bearer realm=".../service/token",service="harbor-registry"
(and the scope of the request); /service/token?service=harbor-registry&scope=repository:<name>:pull gives anonymous tokens
for the public projects only; a token is good for the repositories of its scope only. Basic credentials of an account in
users.json (what a push uses) are accepted everywhere. It is a stand-in for Harbor, not the Harbor product.

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
import time
import urllib.parse
import uuid

root, port, logfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
CERT, KEY = os.environ.get("REG_CERT"), os.environ.get("REG_KEY")
org = sys.argv[4] if len(sys.argv) > 4 else ""
USERS = json.load(open(sys.argv[5])) if len(sys.argv) > 5 else None
HARBOR = set(p for p in os.environ.get("REG_HARBOR", "").split(",") if p)    # public projects (Harbor mode)
SERVICE = "harbor-registry"
SECRET = os.urandom(16)
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


    # ---- Harbor mode ------------------------------------------------------------------------
    def _token_for(self, names):
        payload = json.dumps({"n": sorted(names), "e": int(time.time()) + 300})
        sig = hmac.new(SECRET, payload.encode(), "sha256").hexdigest()
        return base64.urlsafe_b64encode((payload + "." + sig).encode()).decode()

    def _token_names(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Bearer "):
            return None
        try:
            payload, _, sig = base64.urlsafe_b64decode(h[7:]).decode().rpartition(".")
            if not hmac.compare_digest(sig, hmac.new(SECRET, payload.encode(), "sha256").hexdigest()):
                return None
            d = json.loads(payload)
            return set(d["n"]) if d["e"] > time.time() else None
        except (ValueError, KeyError, TypeError):
            return None

    def _challenge(self, scope, head):
        realm = "http://%s/service/token" % self.headers.get("Host", "")
        c = 'Bearer realm="%s",service="%s"' % (realm, SERVICE)
        if scope:
            c += ',scope="repository:%s:pull"' % scope
        body = json.dumps({"errors": [{"code": "UNAUTHORIZED", "message": "unauthorized: authentication required"}]}).encode()
        self._reply(401, body, headers={"WWW-Authenticate": c}, head=head)

    def _harbor_gate(self, m, head):
        """True when the request may go on to the registry routes; otherwise the answer was sent."""
        path, _, query = self.path.partition("?")
        params = {k: urllib.parse.unquote(v) for k, v in (p.split("=", 1) for p in query.split("&") if "=" in p)}
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic ") and self._authenticated():
            return True                                    # an account of the registry (the push of setup)
        if path == "/service/token":
            self._body()
            if params.get("service") != SERVICE:
                self._err(400, "BAD_REQUEST", "unknown service", head)
                return False
            names = set()
            for sc in [v for k, v in (p.split("=", 1) for p in query.split("&") if "=" in p) if k == "scope"]:
                kind, _, rest = urllib.parse.unquote(sc).partition(":")
                nm = rest.rpartition(":")[0]
                if kind == "repository" and nm.split("/")[0] in HARBOR and "/" in nm:
                    names.add(nm)
            self._note = " scope=%s" % ",".join(sorted(names))
            tok = self._token_for(names)
            self._reply(200, json.dumps({"token": tok, "access_token": tok, "expires_in": 300}).encode(), head=head)
            return False
        names = self._token_names()
        self._who = " auth=bearer:%s" % ",".join(sorted(names)) if names is not None else " auth=none"
        if path in ("/v2/", "/v2"):
            if names is None:
                self._challenge("", head)
                return False
            return True
        mt = re.match(r"^/v2/(.+)/(manifests|blobs|tags)/(.*)$", path)
        if not mt:
            self._reply(404, b"404 page not found\n", ctype="text/plain; charset=utf-8", head=head)
            return False
        name = mt.group(1)
        if "/" not in name:
            self._body()
            self._err(400, "NAME_INVALID", "repository name must have the form <project>/<repository>: %s" % name, head)
            return False
        if name.split("/")[0] not in HARBOR:
            self._body()
            self._err(404, "NAME_UNKNOWN", "project not found: %s" % name.split("/")[0], head)
            return False
        if names is None or name not in names:
            self._challenge(name, head)
            return False
        return True

    # ---- routing --------------------------------------------------------------------------
    def _route(self, m):
        head = m == "HEAD"
        if HARBOR:
            if not self._harbor_gate(m, head):
                return
        elif not self._authenticated():
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
sudo touch "$REG_DIR/requests.log"
REG_PASS="pw-$(python3 -c 'import secrets; print(secrets.token_hex(10))')"
python3 -c 'import json,sys; print(json.dumps({sys.argv[1]: sys.argv[2]}))' "$REG_USER" "$REG_PASS" \
    | sudo sh -c 'umask 077; cat > "$1"' _ "$REG_DIR/users.json"
sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$REG_PASS" "$STATE_DIR/regpass"
start_daemon "$REG_DIR/registry.pid" "$REG_DIR/registry.out" \
    env REG_HARBOR="$PROJECT" python3 "$REG_DIR/registry.py" "$REG_DIR" "$REG_PORT" "$REG_DIR/requests.log" "" "$REG_DIR/users.json"
for _ in $(seq 1 40); do
    [ "$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$REG_PORT/v2/" 2>/dev/null)" = "401" ] && break
    sleep 0.25
done
[ "$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$REG_PORT/v2/" 2>/dev/null)" = "401" ] \
    || { echo "[setup] ERROR: the registry did not come up"; sudo tail -5 "$REG_DIR/registry.out" 2>/dev/null; exit 1; }
echo "  -> registry up on 127.0.0.1:$REG_PORT (/v2/ answers 401 with a Bearer challenge, as Harbor does)"

echo "[setup] caching the image in project $PROJECT as $HARBOR_REPO:$TAG (the build inputs of the image stay out of the machine)..."
REG_AUTH="$REG_USER:$REG_PASS" python3 "$STATE_DIR/mkimg.py" push "http://127.0.0.1:$REG_PORT" "$HARBOR_REPO" "$TAG" "$STATE_DIR/app" app > "$STATE_DIR/image.truth" \
    || { echo "[setup] ERROR: could not push the image to the registry"; exit 1; }
cat "$STATE_DIR/image.truth"
python3 "$STATE_DIR/mkimg.py" tar "$STATE_DIR/pause.tar" "$PAUSE_REF" "$STATE_DIR/pause" pause >/dev/null
MDIGEST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/image.truth")
echo "$MDIGEST" > "$STATE_DIR/manifest.digest"
curl -sf -u "$REG_USER:$REG_PASS" "http://127.0.0.1:$REG_PORT/v2/$HARBOR_REPO/tags/list" | grep -q "\"$TAG\"" \
    || { echo "[setup] ERROR: the registry does not list the tag"; exit 1; }
echo "  -> $REG_HOST:$REG_PORT/$HARBOR_REPO:$TAG = $MDIGEST"

echo "[setup] starting the egress proxy of this machine (HTTP proxy on 127.0.0.1:$HUB_PORT): the only way out for containerd."
echo "[setup] It resolves and reaches Harbor by name and refuses (403) everything else, $UPSTREAM included; every request is logged..."
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

echo "[setup] starting the pre-installed containerd (the runtime of this machine: own socket, root and state;"
echo "[setup] containerd's own default config for the installed version, moved into that root/state, NRI off). Its registry"
echo "[setup] configuration is the one of the question: a mirror of $UPSTREAM whose endpoint is Harbor plus the project;"
echo "[setup] its Internet access goes through the egress proxy..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock, cni, pause, upstream, endpoint = sys.argv[1:8]
section = ""
registry_section = ""
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
        if section.endswith(".registry") and "cri" in section:
            registry_section = m.group(1)
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
        # the registry configuration of the question is the legacy mirrors table (below); it excludes config_path
        line = f"{indent}config_path = ''\n"
    elif "pinned_images" in section and k == "sandbox":
        line = f"{indent}sandbox = '{pause}'\n"
    elif k == "sandbox_image":
        line = f"{indent}sandbox_image = '{pause}'\n"
    sys.stdout.write(line)
sys.stdout.write("\n# the mirror of the question: the endpoint is Harbor's address plus the name of the proxy cache project\n")
sys.stdout.write(f"[{registry_section}.mirrors.'{upstream}']\n  endpoint = ['{endpoint}']\n")
PYEOF
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" "$UPSTREAM" "$BAD_ENDPOINT" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
grep -q "$PAUSE_REF" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
grep -q "mirrors.'$UPSTREAM'" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not write the mirror of the question into the containerd config"; exit 1; }
cat <<CEOF | sudo tee "$CTL_DIR/containerdctl" >/dev/null
#!/bin/bash
# how this machine's containerd is started and stopped: containerdctl start|stop|restart|status
# (this machine reaches anything only through its egress proxy, so containerd runs with the proxy variables)
PIDF="$RUN_BASE/containerd.pid"
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
$CTR -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 \
    || { echo "[setup] ERROR: ctr could not import the sandbox image"; exit 1; }
rm -f "$STATE_DIR/pause.tar"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 60s)
"${CRI[@]}" version >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI of containerd does not answer"; exit 1; }
echo "  -> CRI answers"

echo "[setup] recording the identity of the daemons (pid + start time)..."
for d in containerd; do
    P=$(cat "$RUN_BASE/$d.pid")
    echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/$d.id"
done
P=$(cat "$REG_DIR/registry.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/registry.id"
P=$(cat "$HUB_DIR/hubgate.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/hubgate.id"
# what the registry holds now, to prove later that nobody changed it
sudo cp "$REG_DIR/state.json" "$STATE_DIR/registry.state0"

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/pause" "$STATE_DIR/pause.c" "$STATE_DIR/mkimg.py" \
    "$STATE_DIR/patch_config.py" "$STATE_DIR/registry.py" "$STATE_DIR/hubgate.py"

echo "[setup] done. Harbor ($REG_HOST:$REG_PORT, project $PROJECT) holds $HARBOR_REPO:$TAG; containerd mirrors $UPSTREAM to"
echo "[setup] $BAD_ENDPOINT, as in the question."
