#!/bin/bash
set -e

CASE_ID="bench76836830"
RUN_BASE="/run/$CASE_ID"              # the private containerd (socket, state, config), pid files of the daemons
LIB_BASE="/var/lib/$CASE_ID"          # containerd root, the registry's blobs, the stand-ins' programs
WORK_DIR="/tmp/$CASE_ID"              # what the job has: the nginx directory, the wrappers
STATE_DIR="$WORK_DIR/.bench"          # root-only record of what is true
CTD_SOCK="$RUN_BASE/containerd.sock"
NGX_DIR="$WORK_DIR/nginx"
NGX_PORT=18076                        # the nginx in front of "Nexus" (the address nodes pull from)
REG_PORT=15076                        # "Nexus"' Docker repository connector (the 5000 of the thread)
WEB_PORT=18176                        # "Nexus"' web application (8081)
ORG="$CASE_ID"; REPO="$ORG/app"; TAG="1.0"
REF="127.0.0.1:$NGX_PORT/$REPO:$TAG"
CRICTL_VERSION="v1.34.0"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

case "$(uname -m)" in
    x86_64|amd64)  CRICTL_ARCH="amd64" ;;
    aarch64|arm64) CRICTL_ARCH="arm64" ;;
    *) echo "[setup] NOT APPLICABLE: $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking what the case needs is installed (containerd, ctr and runc of this host are the runtime under test)..."
for c in containerd ctr runc python3 curl sudo sha256sum; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }; done
containerd --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc (one tiny static program is the image), crictl and nginx exist..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" -o /tmp/crictl.tar.gz
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin; rm -f /tmp/crictl.tar.gz
fi
if ! command -v nginx >/dev/null 2>&1; then
    echo "[setup] installing nginx (its system service is not started: this case runs its own instance)..."
    GUARD=""; [ -e /usr/sbin/policy-rc.d ] || { printf '#!/bin/sh\nexit 101\n' | sudo tee /usr/sbin/policy-rc.d >/dev/null; sudo chmod 0755 /usr/sbin/policy-rc.d; GUARD=1; }
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" nginx
    [ -z "$GUARD" ] || sudo rm -f /usr/sbin/policy-rc.d
    sudo systemctl disable nginx >/dev/null 2>&1 || true
fi
NGINX_BIN=$(readlink -f "$(command -v nginx)")
echo "  -> $($NGINX_BIN -v 2>&1), crictl $(crictl --version | awk '{print $3}')"

echo "[setup] resetting the case directories..."
sudo rm -rf "$WORK_DIR" "$LIB_BASE" "$RUN_BASE"
mkdir -p "$STATE_DIR" "$NGX_DIR/logs" "$WORK_DIR/bin"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$LIB_BASE/registry" "$LIB_BASE/bin"
chmod 755 "$WORK_DIR" "$STATE_DIR"
cd "$WORK_DIR"

# detached daemon launcher: $1 pid file, $2 log file, rest = the command (exec keeps the pid)
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] building the image offline, in DOCKER format: one layer with a static program that prints a per-run token..."
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
cat > "$STATE_DIR/app.c" <<CEOF
#include <stdio.h>
int main(void) { puts("$CASE_ID-app-ok token=$TOKEN"); return 0; }
CEOF
gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$TOKEN" "$STATE_DIR/token"
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

ref, token, app_bin, out = sys.argv[1:5]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"


def layer_tar():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data, mode in (("app", open(app_bin, "rb").read(), 0o755),):
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, 1700000000
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


layer = layer_tar()
diff_id = sha(layer)                                   # digest of the uncompressed layer
gz = io.BytesIO()
with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
    g.write(layer)
layer_gz = gz.getvalue()                               # Docker layers are gzip: blob digest != diff id
config = json.dumps({
    "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "docker_version": "20.10.21",
    "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
               "Entrypoint": ["/app"], "Cmd": [], "WorkingDir": "/"},
    "container_config": {"Cmd": ["/bin/sh", "-c", "#(nop) ", "ENTRYPOINT [\"/app\"]"]},
    "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY app / # buildkit"},
                {"created": "2023-11-14T22:13:20Z", "created_by": "ENTRYPOINT [\"/app\"]",
                 "empty_layer": True}],
    "rootfs": {"type": "layers", "diff_ids": [diff_id]}}, separators=(",", ":")).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": DOCKER_MANIFEST,
                       "config": {"mediaType": DOCKER_CONFIG, "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": DOCKER_LAYER, "digest": sha(layer_gz), "size": len(layer_gz)}]},
                      separators=(",", ":")).encode()
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
print(json.dumps({"config": sha(config), "config_size": len(config), "manifest": sha(manifest),
                  "manifest_size": len(manifest), "diff_id": diff_id, "layer": sha(layer_gz),
                  "layer_size": len(layer_gz), "media_type": DOCKER_MANIFEST}))
PYEOF
python3 "$STATE_DIR/mkimg.py" "docker.io/$REPO:$TAG" "$TOKEN" "$STATE_DIR/app" "$STATE_DIR/image.tar" > "$STATE_DIR/image.truth"

echo "[setup] the two stand-ins of Nexus: the Docker repository connector (a small registry, 127.0.0.1:$REG_PORT, request log with User-Agent) and the web application (127.0.0.1:$WEB_PORT, an HTML page at / and 404 for everything else, /v2/ included)..."
cat > "$STATE_DIR/registry.py" <<'PYEOF'
"""A minimal, read-write OCI/Docker distribution registry (HTTP, no auth) for the case.

Rules: a repository name is a path of lowercase components (any depth, as in the distribution spec);
writes (blob uploads, manifest puts) are only accepted below the one fixed organisation prefix; blobs
are visible only in the repository they were pushed to (as in a real registry); a manifest is only
accepted when its config and layers are already in that repository. Every request is logged with its
status and User-Agent; the state (repositories, tags, manifests, blobs) is written to state.json.
"""
import hashlib
import http.server
import json
import os
import re
import sys
import threading
import urllib.parse
import uuid

root, port, logfile, org = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
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
            LOG.write("%s %s %s ua=%s%s\n" % (method, self.path, self._status,
                                              self.headers.get("User-Agent", ""), self._note))

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
        if write and not name.startswith(org + "/"):
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


save_state()
S(("127.0.0.1", port), H).serve_forever()
PYEOF
cat > "$STATE_DIR/web.py" <<'PYEOF'
import http.server
import sys

port, token = int(sys.argv[1]), sys.argv[2]
PAGE = ("<html><head><title>Nexus Repository Manager</title></head><body><h1>Nexus Repository Manager</h1>"
        "<p>nexus-ui-%s</p></body></html>" % token).encode()
NOTFOUND = b"<html><body><h1>404 Not Found</h1></body></html>"


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _go(self, body_too):
        page = self.path.split("?")[0] in ("/", "/index.html")
        body, code = (PAGE, 200) if page else (NOTFOUND, 404)
        self.send_response(code)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body_too:
            self.wfile.write(body)

    def do_GET(self):
        self._go(True)

    def do_HEAD(self):
        self._go(False)

    def log_message(self, *a):
        pass


class S(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


S(("127.0.0.1", port), H).serve_forever()
PYEOF
sudo cp "$STATE_DIR/registry.py" "$LIB_BASE/registry/registry.py"
sudo cp "$STATE_DIR/web.py" "$LIB_BASE/bin/web.py"
sudo touch "$LIB_BASE/registry/requests.log"
start_daemon "$RUN_BASE/registry.pid" "$RUN_BASE/registry.out" python3 "$LIB_BASE/registry/registry.py" "$LIB_BASE/registry" "$REG_PORT" "$LIB_BASE/registry/requests.log" "$ORG"
start_daemon "$RUN_BASE/web.pid" "$RUN_BASE/web.out" python3 "$LIB_BASE/bin/web.py" "$WEB_PORT" "$TOKEN"
for _ in $(seq 1 40); do
    curl -sf --max-time 2 "http://127.0.0.1:$REG_PORT/v2/" >/dev/null 2>&1 && curl -sf --max-time 2 "http://127.0.0.1:$WEB_PORT/" >/dev/null 2>&1 && break
    sleep 0.25
done
curl -sf --max-time 2 "http://127.0.0.1:$REG_PORT/v2/" >/dev/null || { echo "[setup] ERROR: the registry did not come up (is port $REG_PORT taken?)"; sudo tail -5 "$RUN_BASE/registry.out"; exit 1; }
curl -sf --max-time 2 "http://127.0.0.1:$WEB_PORT/" >/dev/null || { echo "[setup] ERROR: the web stand-in did not come up (is port $WEB_PORT taken?)"; sudo tail -5 "$RUN_BASE/web.out"; exit 1; }
echo "  -> registry on 127.0.0.1:$REG_PORT, web application on 127.0.0.1:$WEB_PORT"

echo "[setup] starting a PRIVATE containerd (own socket, root and state; a minimal version-2 configuration that every 1.7/2.x containerd reads; CRI plugin on, NRI off)..."
sudo tee "$RUN_BASE/config.toml" >/dev/null <<EOF
version = 2
root = "$LIB_BASE/containerd"
state = "$RUN_BASE"
[grpc]
  address = "$CTD_SOCK"
[ttrpc]
  address = "$CTD_SOCK.ttrpc"
[plugins."io.containerd.nri.v1.nri"]
  disable = true
[plugins."io.containerd.grpc.v1.cri"]
  restrict_oom_score_adj = true
EOF
start_daemon "$RUN_BASE/containerd.pid" "$RUN_BASE/containerd.log" containerd --config "$RUN_BASE/config.toml"
for _ in $(seq 1 60); do
    [ -S "$CTD_SOCK" ] && sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the private containerd did not come up; last log lines:"; sudo tail -20 "$RUN_BASE/containerd.log"; exit 1; }
echo "  -> containerd up on $CTD_SOCK"

echo "[setup] publishing the image to the registry (straight to its port) and removing it from the node again (images AND content), so the first pull of the job is a cold one..."
CTR="sudo ctr -a $CTD_SOCK -n k8s.io"
DIRECT="127.0.0.1:$REG_PORT/$REPO:$TAG"
$CTR images import "$STATE_DIR/image.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import the image"; exit 1; }
$CTR images tag "docker.io/$REPO:$TAG" "$DIRECT" >/dev/null 2>&1
$CTR images push --plain-http "$DIRECT" >/dev/null 2>&1 || { echo "[setup] ERROR: could not push the image to the registry"; exit 1; }
for i in $($CTR images ls -q 2>/dev/null); do $CTR images rm --sync "$i" >/dev/null 2>&1 || true; done
for _ in $(seq 1 40); do [ "$($CTR content ls -q 2>/dev/null | wc -l)" = "0" ] && break; sleep 0.5; done
[ "$($CTR content ls -q 2>/dev/null | wc -l)" = "0" ] || { echo "[setup] ERROR: the node still holds content after the removal"; exit 1; }
rm -f "$STATE_DIR/image.tar" "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/mkimg.py" "$STATE_DIR/registry.py" "$STATE_DIR/web.py"
curl -s -o /dev/null -w "  -> the registry serves the manifest (HTTP %{http_code}); the node holds no image and no content\n" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "http://127.0.0.1:$REG_PORT/v2/$REPO/manifests/$TAG"

echo "[setup] the nginx in front of Nexus (the job's: $NGX_DIR/nginx.conf; the rule 'if (\$http_user_agent ~ docker) -> Docker repository connector, else the web application' is what the thread describes)..."
cat > "$NGX_DIR/nginx.conf" <<EOF
worker_processes 1;
pid $NGX_DIR/nginx.pid;
error_log $NGX_DIR/logs/error.log;
events { worker_connections 64; }
http {
    log_format front '\$remote_addr "\$request" \$status ua="\$http_user_agent" upstream=\$upstream_addr';
    access_log $NGX_DIR/logs/access.log front;
    client_max_body_size 0;
    server {
        listen 127.0.0.1:$NGX_PORT;
        # Nexus: the web application is on $WEB_PORT, the Docker repository connector on $REG_PORT
        location / {
            if (\$http_user_agent ~ docker) {
                proxy_pass http://127.0.0.1:$REG_PORT;
            }
            proxy_pass http://127.0.0.1:$WEB_PORT;
        }
    }
}
EOF
chmod 644 "$NGX_DIR/nginx.conf"
cat > "$WORK_DIR/bin/nginxctl" <<EOF
#!/bin/sh
# nginxctl test|start|reload|stop|restart: this case's nginx (prefix $NGX_DIR, configuration $NGX_DIR/nginx.conf)
N="sudo $NGINX_BIN -p $NGX_DIR -c $NGX_DIR/nginx.conf"
case "\$1" in
    test)    exec \$N -t ;;
    start)   exec \$N ;;
    reload)  exec \$N -s reload ;;
    stop)    exec \$N -s stop ;;
    restart) \$N -s stop; sleep 1; exec \$N ;;
    *) echo "usage: nginxctl test|start|reload|stop|restart" >&2; exit 2 ;;
esac
EOF
cat > "$WORK_DIR/bin/pull" <<EOF
#!/bin/sh
# pull: the pull step of the job: what the kubelet asks the node's container runtime for (CRI PullImage) for the image of the workload
exec sudo crictl --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK --timeout 60s pull $REF
EOF
cat > "$WORK_DIR/bin/node-crictl" <<EOF
#!/bin/sh
# node-crictl ARGS...: crictl against the node's containerd
exec sudo crictl --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK "\$@"
EOF
chmod 0755 "$WORK_DIR/bin/nginxctl" "$WORK_DIR/bin/pull" "$WORK_DIR/bin/node-crictl"
"$WORK_DIR/bin/nginxctl" test >/dev/null 2>&1 || { echo "[setup] ERROR: nginx does not accept its configuration"; "$WORK_DIR/bin/nginxctl" test; exit 1; }
"$WORK_DIR/bin/nginxctl" start
for _ in $(seq 1 40); do curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$NGX_PORT/" && break; sleep 0.25; done
curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$NGX_PORT/" || { echo "[setup] ERROR: nginx does not answer on 127.0.0.1:$NGX_PORT"; sudo tail -5 "$NGX_DIR/logs/error.log"; exit 1; }
echo "  -> nginx on 127.0.0.1:$NGX_PORT"

echo "[setup] recording the state (root-only): daemons (pid + start time), hashes of the programs, the wrappers and the node's configuration, the image's digests..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" NGX_DIR="$NGX_DIR" NGINX_BIN="$NGINX_BIN" REF="$REF" REPO="$REPO" TAG="$TAG" TOKEN="$TOKEN" python3 - <<'PYEOF'
import hashlib, json, os
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def ident(name):
    pid = int(open("%s/%s.pid" % (E["RUN_BASE"], name)).read())
    s = open("/proc/%d/stat" % pid).read()
    return [pid, int(s[s.rindex(")") + 2:].split()[19]), os.readlink("/proc/%d/exe" % pid)]
files = [E["RUN_BASE"] + "/config.toml", E["LIB_BASE"] + "/registry/registry.py", E["LIB_BASE"] + "/bin/web.py"] + [E["WORK_DIR"] + "/bin/" + n for n in ("nginxctl", "pull", "node-crictl")]
truth = json.load(open(E["STATE_DIR"] + "/image.truth"))
d = {"daemons": {n: ident(n) for n in ("containerd", "registry", "web")}, "files": {f: sha(f) for f in files},
     "nginx_bin": E["NGINX_BIN"], "nginx_conf": E["NGX_DIR"] + "/nginx.conf", "ref": E["REF"], "repo": E["REPO"], "tag": E["TAG"], "token": E["TOKEN"], "image": truth}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. nginx (127.0.0.1:$NGX_PORT) is in front of the Nexus stand-ins; the node's containerd holds no image; the job's files are in $WORK_DIR."
