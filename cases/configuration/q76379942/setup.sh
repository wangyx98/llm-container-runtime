#!/bin/bash
set -e

CASE_ID="bench76379942"
RUN_BASE="/run/$CASE_ID"              # containerd's socket, pid files and logs
LIB_BASE="/var/lib/$CASE_ID"          # containerd's root and configuration, the Nexus stand-in's files, the control script
CTD_SOCK="$RUN_BASE/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
NEXUS_DIR="$LIB_BASE/nexus"           # the stand-in's blobs, state.json, requests.log and its configuration file
NEXUS_ADDR="10.66.79.42"              # an address of its own (a /32 alias of lo, so it is not a loopback address for containerd): the host of "repo.mm.mm" of the thread
NEXUS_PORT=18083                      # where the Docker connector of Nexus really listens (plain HTTP)
ENG_PORT=8082                         # the port the engineer's configuration and image names use: nothing listens there
ORG="$CASE_ID"                        # the one repository prefix the stand-in accepts writes for
PAUSE_IMG="localhost/$CASE_ID/pause:1"

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL="sudo crictl --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK"
CTR="sudo ctr -a $CTD_SOCK -n k8s.io"

echo "[setup] checking containerd, ctr, crictl, curl, python3 and ip are installed (containerd is the runtime under test; this case runs a private"
echo "[setup] instance of it with its own socket and root: the machine's own containerd service is not touched)..."
for b in containerd ctr crictl curl python3 sudo ip sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking the address $NEXUS_ADDR and the ports $NEXUS_PORT and $ENG_PORT are free..."
! ip -4 addr show dev lo 2>/dev/null | grep -qF "$NEXUS_ADDR/" || { echo "[setup] ERROR: $NEXUS_ADDR is already an address of this host"; exit 1; }
for p in $NEXUS_PORT $ENG_PORT; do
    ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$" || { echo "[setup] ERROR: something already listens on port $p"; exit 1; }
done
for f in /etc/containerd/certs.d/docker.io/hosts.toml; do
    ! sudo grep -qF "$NEXUS_ADDR" "$f" 2>/dev/null || { echo "[setup] ERROR: $f already names $NEXUS_ADDR"; exit 1; }
done

echo "[setup] making sure gcc is available (the images are static programs, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/etc" "$LIB_BASE/bin" "$NEXUS_DIR/etc"
cd "$WORK_DIR"

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of the daemon itself (exec keeps the pid);
# setsid + all three fds redirected so it outlives this script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] the address of Nexus: $NEXUS_ADDR/32 on lo..."
sudo ip addr add "$NEXUS_ADDR/32" dev lo

echo "[setup] building the images offline, in DOCKER format: two applications, each in two tags (1.0 and verify, each tag with a token of its own: a static program that"
echo "[setup] prints a line with its token every 5 seconds), and the sandbox image of the pods..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static void bye(int s) { (void)s; _exit(0); }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGTERM, bye);
    for (;;) {
        puts("bench76379942-app-ok token=" TOKEN);
        sleep(5);
    }
}
CEOF
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <signal.h>
#include <unistd.h>

static void bye(int s) { (void)s; _exit(0); }

int main(void) {
    signal(SIGTERM, bye);
    for (;;) pause();
}
CEOF
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
for k in web webv api apiv; do
    t="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
    echo "$t" > "$STATE_DIR/token.$k"
    gcc -static -Os -s -w -DTOKEN="\"$t\"" -o "$STATE_DIR/app.$k" "$STATE_DIR/app.c"
done
gcc -static -Os -s -w -o "$STATE_DIR/pause" "$STATE_DIR/pause.c"
mk() { python3 "$STATE_DIR/mkimg.py" "$1" "$2" "$STATE_DIR/app.$3" "$STATE_DIR/$3.tar" > "$STATE_DIR/$3.json"; }
mk "bench76379942/web:1.0"    "$(cat "$STATE_DIR/token.web")"  web
mk "bench76379942/web:verify" "$(cat "$STATE_DIR/token.webv")" webv
mk "bench76379942/api:1.0"    "$(cat "$STATE_DIR/token.api")"  api
mk "bench76379942/api:verify" "$(cat "$STATE_DIR/token.apiv")" apiv
python3 "$STATE_DIR/mkimg.py" "$PAUSE_IMG" "pause" "$STATE_DIR/pause" "$STATE_DIR/pause.tar" > "$STATE_DIR/pause.json"

echo "[setup] the stand-in of Nexus (its Docker connector: plain HTTP on $NEXUS_ADDR:$NEXUS_PORT; every request is logged), then the four images pushed with the distribution API..."
cat > "$STATE_DIR/registry.py" <<'PYEOF'
"""A minimal, read-write OCI/Docker distribution registry (HTTP; Basic authentication for /v2/ and for the repositories below one prefix) for the case.

Rules: a repository name is a path of lowercase components (any depth, as in the distribution spec);
writes (blob uploads, manifest puts) are only accepted below the one fixed organisation prefix; blobs
are visible only in the repository they were pushed to (as in a real registry); a manifest is only
accepted when its config and layers are already in that repository. Every request is logged with its
status and User-Agent; the state (repositories, tags, manifests, blobs) is written to state.json.
"""
import base64
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
BIND = sys.argv[5]                      # the address the registry listens on (the Nexus stand-in listens on one address only)
AUTH_USER, AUTH_PASS, PRIVATE = "", "", ""   # no authentication in this case
AUTH_HEADER = "Basic " + base64.b64encode((AUTH_USER + ":" + AUTH_PASS).encode()).decode()
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
        got = self.headers.get("Authorization", "")
        if AUTH_USER and (path in ("/v2/", "/v2") or path.startswith("/v2/" + PRIVATE + "/")):
            ok = got == AUTH_HEADER
            self._note = " auth=" + ("ok" if ok else ("bad" if got else "none"))
            if not ok:
                self._body()
                return self._reply(401, json.dumps({"errors": [{"code": "UNAUTHORIZED", "message": "authentication required"}]}).encode(),
                                   headers={"WWW-Authenticate": 'Basic realm="bench registry"'}, head=head)
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
        self._note += " digest=%s" % digest
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
            self._note += " digest=%s" % digest
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
        self._note += " digest=%s" % digest
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
S((BIND, port), H).serve_forever()
PYEOF
sudo install -m 0644 "$STATE_DIR/registry.py" "$NEXUS_DIR/registry.py"
cat <<EOF | sudo tee "$NEXUS_DIR/etc/nexus.properties" >/dev/null
# configuration of this Nexus (the web application and the Docker connector of the repository docker-all)
application-host=$NEXUS_ADDR
application-port=8081
nexus.docker.docker-all.http.host=$NEXUS_ADDR
nexus.docker.docker-all.http.port=$NEXUS_PORT
nexus.docker.docker-all.http.tls=false
EOF
sudo chmod 644 "$NEXUS_DIR/etc/nexus.properties"
start_daemon "$RUN_BASE/nexus.pid" "$RUN_BASE/nexus.out" python3 "$NEXUS_DIR/registry.py" "$NEXUS_DIR" "$NEXUS_PORT" "$NEXUS_DIR/requests.log" "$ORG" "$NEXUS_ADDR"
for _ in $(seq 1 40); do curl -s --max-time 2 -o /dev/null "http://$NEXUS_ADDR:$NEXUS_PORT/v2/" && break; sleep 0.25; done
curl -s --max-time 2 -o /dev/null "http://$NEXUS_ADDR:$NEXUS_PORT/v2/" || { echo "[setup] ERROR: the Nexus stand-in did not come up"; sudo tail -5 "$RUN_BASE/nexus.out"; exit 1; }
cat > "$STATE_DIR/push.py" <<'PYEOF'
import http.client, json, sys, tarfile
tarp, meta, host, port, repo, tag = sys.argv[1:7]
m = json.load(open(meta)); t = tarfile.open(tarp)
def blob(d): return t.extractfile("blobs/sha256/" + d.split(":")[1]).read()
def req(method, path, body=None, hdr=None):
    c = http.client.HTTPConnection(host, int(port)); c.request(method, path, body=body, headers=hdr or {}); r = c.getresponse(); r.read(); return r.status
for d in (m["config"], m["layer"]):
    s = req("POST", "/v2/%s/blobs/uploads/?digest=%s" % (repo, d), blob(d), {"Content-Type": "application/octet-stream"})
    assert s in (201, 202), "blob upload: HTTP %d" % s
s = req("PUT", "/v2/%s/manifests/%s" % (repo, tag), blob(m["manifest"]), {"Content-Type": m["media_type"]})
assert s == 201, "manifest put: HTTP %d" % s
PYEOF
for spec in "web bench76379942/web 1.0" "webv bench76379942/web verify" "api bench76379942/api 1.0" "apiv bench76379942/api verify"; do
    set -- $spec
    python3 "$STATE_DIR/push.py" "$STATE_DIR/$1.tar" "$STATE_DIR/$1.json" "$NEXUS_ADDR" "$NEXUS_PORT" "$2" "$3" || { echo "[setup] ERROR: could not push $2:$3"; exit 1; }
done
echo "  -> $(curl -s "http://$NEXUS_ADDR:$NEXUS_PORT/v2/_catalog" | tr -d ' \n')"

echo "[setup] the engineer's containerd: its own configuration $CTD_CONF (a version-3 file: the registry mirror for docker.io is the one of the thread, pointing at"
echo "[setup] port $ENG_PORT), the sandbox image of the pods imported, and the script that starts and stops it..."
sudo tee "$CTD_CONF" >/dev/null <<EOF
version = 3
root = "$LIB_BASE/containerd"
state = "$RUN_BASE/state"
[grpc]
  address = "$CTD_SOCK"
[ttrpc]
  address = "$CTD_SOCK.ttrpc"
[plugins."io.containerd.nri.v1.nri"]
  disable = true
[plugins."io.containerd.cri.v1.runtime"]
  restrict_oom_score_adj = true
[plugins."io.containerd.cri.v1.images".pinned_images]
  sandbox = "$PAUSE_IMG"
[plugins."io.containerd.cri.v1.images".registry]
  config_path = ""
[plugins."io.containerd.cri.v1.images".registry.mirrors]
  [plugins."io.containerd.cri.v1.images".registry.mirrors."docker.io"]
    endpoint = ["http://$NEXUS_ADDR:$ENG_PORT"]
EOF
sudo chmod 644 "$CTD_CONF"
sudo tee "$LIB_BASE/bin/containerdctl" >/dev/null <<EOF
#!/bin/bash
# containerdctl start|stop|restart|status: this machine's containerd, like \`systemctl start|stop|restart containerd\` (run it with sudo).
# containerd reads $CTD_CONF only when it starts.
PIDF="$RUN_BASE/containerd.pid"
alive() { local p; [ -s "\$PIDF" ] && p=\$(cat "\$PIDF") && [ "\$(cat "/proc/\$p/comm" 2>/dev/null)" = "containerd" ]; }
do_start() {
    alive && { echo "containerd is already running"; return 0; }
    setsid -f bash -c 'echo \$\$ > "\$1"; exec "\$2" --config "\$3" >>"\$4" 2>&1 </dev/null' _ "\$PIDF" "$(command -v containerd)" "$CTD_CONF" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
    for _ in \$(seq 1 60); do "$(command -v ctr)" -a "$CTD_SOCK" version >/dev/null 2>&1 && break; sleep 0.5; done
    "$(command -v ctr)" -a "$CTD_SOCK" version >/dev/null 2>&1 && echo "containerd started" || { echo "containerd did not come up"; tail -5 "$RUN_BASE/containerd.log"; return 1; }
}
do_stop() {
    alive || { echo "containerd is not running"; return 0; }
    p=\$(cat "\$PIDF"); kill -TERM "\$p"
    for _ in \$(seq 1 60); do kill -0 "\$p" 2>/dev/null || break; sleep 0.5; done
    kill -0 "\$p" 2>/dev/null && kill -KILL "\$p"
    echo "containerd stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid \$(cat "\$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: containerdctl start|stop|restart|status"; exit 2 ;;
esac
EOF
sudo chmod 755 "$LIB_BASE/bin/containerdctl"
sudo "$LIB_BASE/bin/containerdctl" start >/dev/null || { echo "[setup] ERROR: the private containerd did not come up"; sudo tail -15 "$RUN_BASE/containerd.log" | cut -c1-250; exit 1; }
$CTR images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import the sandbox image"; exit 1; }
# the CRI must know the imported sandbox image; if it does not, show why (a CRI plugin that failed to load is in containerd's log)
for _ in $(seq 1 10); do $CRICTL inspecti "$PAUSE_IMG" >/dev/null 2>&1 && break; sleep 1; done
if ! $CRICTL inspecti "$PAUSE_IMG" >/dev/null 2>&1; then
  echo "[setup] ERROR: the CRI does not see the sandbox image"
  echo "  ctr images:   $($CTR images ls -q 2>&1 | tr '\n' ' ')"
  echo "  crictl error: $($CRICTL inspecti "$PAUSE_IMG" 2>&1 | tail -2 | cut -c1-300 | tr '\n' ' ')"
  sudo grep -iE 'error|fail' "$RUN_BASE/containerd.log" | grep -v DEPRECATION | tail -6 | cut -c1-400
  exit 1
fi
echo "  -> containerd $(sudo ctr -a "$CTD_SOCK" version | awk '/Server/ {f=1} f && /Version/ {print $2; exit}') up on $CTD_SOCK; its store holds only the sandbox image"

echo "[setup] the job's wrappers: ctr (against this containerd; ctr's default namespace is \"default\", the CRI's is k8s.io) and node-crictl..."
cat > "$WORK_DIR/bin/ctr" <<EOF
#!/bin/sh
# ctr ARGS...: ctr against this machine's containerd (it calls sudo itself)
exec sudo $(command -v ctr) -a $CTD_SOCK "\$@"
EOF
cat > "$WORK_DIR/bin/node-crictl" <<EOF
#!/bin/sh
# node-crictl ARGS...: crictl against this machine's containerd, the runtime of the kubelet (it calls sudo itself)
exec sudo $(command -v crictl) --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK "\$@"
EOF
chmod 755 "$WORK_DIR/bin/ctr" "$WORK_DIR/bin/node-crictl"

echo "[setup] recording the state (root-only): the daemons (pid + start time + program), hashes, the images' digests and tokens..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" NEXUS_DIR="$NEXUS_DIR" NEXUS_ADDR="$NEXUS_ADDR" NEXUS_PORT="$NEXUS_PORT" ENG_PORT="$ENG_PORT" \
    CTD_CONF="$CTD_CONF" CTD_SOCK="$CTD_SOCK" python3 - <<'PYEOF'
import hashlib, json, os
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def ident(name):
    pid = int(open("%s/%s.pid" % (E["RUN_BASE"], name)).read())
    s = open("/proc/%d/stat" % pid).read()
    return [pid, int(s[s.rindex(")") + 2:].split()[19]), os.readlink("/proc/%d/exe" % pid)]
files = [E["NEXUS_DIR"] + "/registry.py", E["NEXUS_DIR"] + "/etc/nexus.properties", E["LIB_BASE"] + "/bin/containerdctl",
         E["WORK_DIR"] + "/bin/ctr", E["WORK_DIR"] + "/bin/node-crictl"]
imgs = {}
for k, (repo, tag) in {"web": ("bench76379942/web", "1.0"), "webv": ("bench76379942/web", "verify"),
                       "api": ("bench76379942/api", "1.0"), "apiv": ("bench76379942/api", "verify")}.items():
    m = json.load(open("%s/%s.json" % (E["STATE_DIR"], k)))
    imgs[k] = {"repo": repo, "tag": tag, "token": open("%s/token.%s" % (E["STATE_DIR"], k)).read().strip(),
               "manifest": m["manifest"], "config": m["config"], "layer": m["layer"]}
d = {"daemons": {n: ident(n) for n in ("nexus", "containerd")}, "files": {f: sha(f) for f in files},
     "nexus_state": sha(E["NEXUS_DIR"] + "/state.json"), "nexus_lines": sum(1 for _ in open(E["NEXUS_DIR"] + "/requests.log")),
     "addr": E["NEXUS_ADDR"], "port": int(E["NEXUS_PORT"]), "eng_port": int(E["ENG_PORT"]), "images": imgs,
     "ctd_conf": E["CTD_CONF"], "ctd_sock": E["CTD_SOCK"]}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR"/app.* "$STATE_DIR"/app.c "$STATE_DIR"/pause "$STATE_DIR"/pause.c "$STATE_DIR"/*.tar "$STATE_DIR"/*.json.bak "$STATE_DIR"/web*.json "$STATE_DIR"/api*.json "$STATE_DIR"/pause.json \
    "$STATE_DIR"/token.* "$STATE_DIR"/mkimg.py "$STATE_DIR"/push.py "$STATE_DIR"/registry.py
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. Nexus' Docker connector listens on $NEXUS_ADDR:$NEXUS_PORT; the engineer's configuration and image names use port $ENG_PORT, where nothing listens."
