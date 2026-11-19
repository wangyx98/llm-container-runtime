#!/bin/bash
set -e

CASE_ID="bench72183367"
RUN_BASE="/run/$CASE_ID"              # socket, runroot, pid files and logs of CRI-O, k3s and the registry
LIB_BASE="/var/lib/$CASE_ID"          # CRI-O's storage, k3s and its kubelet, the CNI stub, the registry's blobs, the control scripts
CTL_DIR="$LIB_BASE/bin"               # control scripts (not in /run: it is mounted noexec on many hosts)
CRIO_SOCK="$RUN_BASE/crio.sock"
REG_DIR="$LIB_BASE/registry"          # registry blobs, state.json, requests.log (root-owned)
REG_PORT=15183
REG_HOST="127.0.0.1:$REG_PORT"
ORG="$CASE_ID"                        # the one prefix the registry accepts writes for
PRIVATE="$ORG/secure"                 # repositories below it need authentication
REPO="$PRIVATE/app"
TAG="1.0"                             # the image of the job's pod
VTAG="verify"                         # a second image of the same repository, for the oracle's own pull
REF="$REG_HOST/$REPO:$TAG"
PAUSE_REF="$REG_HOST/$ORG/pause:1"    # sandbox ("pause") image; its repository is anonymous
NODE="bench72183367-node"

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

CRICTL="sudo crictl --runtime-endpoint unix://$CRIO_SOCK --image-endpoint unix://$CRIO_SOCK"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking CRI-O, crictl, curl and python3 are installed (CRI-O is the runtime under test; this case runs a private"
echo "[setup] instance of it with its own socket and storage: the machine's own crio service is not touched)..."
for b in crio crictl curl python3 sudo sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
crio --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking this host has no k3s or kubelet of its own (k3s keeps files in fixed places that this"
echo "[setup] case manages), and that the registry port $REG_PORT is free..."
for d in /etc/rancher /var/lib/rancher /run/k3s; do
    [ ! -e "$d" ] || { echo "[setup] ERROR: $d exists: this host has its own k3s state, the case would damage it"; exit 1; }
done
# k3s makes /var/lib/kubelet/device-plugins whatever the kubelet's root-dir is, and an earlier k3s leaves it behind: a tree of empty
# directories (and a stale socket) is no state of a kubelet; files in it (config, pki, pods...) are, and so is anything mounted below it
if [ -e /var/lib/kubelet ]; then
    if [ -n "$(sudo find /var/lib/kubelet -mindepth 1 ! -type d ! -type s 2>/dev/null | head -1)" ] || sudo findmnt -rn -o TARGET 2>/dev/null | grep -qE '^/var/lib/kubelet(/|$)'; then
        echo "[setup] ERROR: /var/lib/kubelet holds files or mounts: this host has its own kubelet state, the case would damage it"; exit 1
    fi
fi
# the kubelet creates these two and never removes them: empty ones are what an earlier k3s case left
for d in /var/log/pods /var/log/containers; do
    if [ -d "$d" ] && [ -n "$(sudo ls -A "$d" 2>/dev/null)" ]; then
        echo "[setup] ERROR: $d is not empty: this host has its own pods or containers logs, the case would damage them"; exit 1
    fi
done
for c in k3s-server k3s-agent kubelet; do
    ! pgrep -x "$c" >/dev/null 2>&1 || { echo "[setup] ERROR: a $c process runs on this host: the case needs a host without k3s or a kubelet"; exit 1; }
done
if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$REG_PORT/" 2>/dev/null; then
    echo "[setup] ERROR: something already listens on 127.0.0.1:$REG_PORT"; exit 1
fi

echo "[setup] making sure gcc is available (two tiny static programs and the pause program are the only files of the images,"
echo "[setup] so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/crio" "$CTL_DIR" "$LIB_BASE/cni/bin" "$LIB_BASE/cni/net.d" "$REG_DIR"
sudo touch "$OWNED_MARKER"      # from here on cleanup.sh may remove the fixed k3s directories
cd "$WORK_DIR"

echo "[setup] locating the k3s binary (the one in the PATH; else $K3S_VERSION is downloaded, and its sha256 checked)..."
K3S_BIN="${BENCH72183367_K3S_BIN:-$(command -v k3s || true)}"
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
"$K3S_BIN" --version | head -1

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of the daemon itself (exec keeps the pid);
# setsid + all three fds redirected so it outlives this script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] the credentials of the registry (made for this run; the job finds them in $WORK_DIR/registry.cred)..."
REG_USER="reader$(python3 -c 'import secrets; print(secrets.token_hex(3))')"
REG_PASS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
printf 'username=%s\npassword=%s\n' "$REG_USER" "$REG_PASS" > "$WORK_DIR/registry.cred"
chmod 644 "$WORK_DIR/registry.cred"

echo "[setup] building the images offline, in DOCKER format (what docker push sends): two application images, each one static program"
echo "[setup] that prints a line with its own random token every 5 seconds (tags $TAG and $VTAG of the same private repository), and the sandbox"
echo "[setup] image of the pods (a static program that only waits)..."
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
VTOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static void bye(int s) { (void)s; _exit(0); }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGTERM, bye);
    for (;;) {
        puts("bench72183367-app-ok token=" TOKEN);
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
gcc -static -Os -s -w -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/app" "$STATE_DIR/app.c"
gcc -static -Os -s -w -DTOKEN="\"$VTOKEN\"" -o "$STATE_DIR/app2" "$STATE_DIR/app.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause" "$STATE_DIR/pause.c"
sudo sh -c 'umask 077; printf "%s\n%s\n" "$1" "$2" > "$3"' _ "$TOKEN" "$VTOKEN" "$STATE_DIR/tokens"
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
python3 "$STATE_DIR/mkimg.py" "$REF" "$TOKEN" "$STATE_DIR/app" "$STATE_DIR/app.tar" > "$STATE_DIR/app.json"
python3 "$STATE_DIR/mkimg.py" "$REG_HOST/$REPO:$VTAG" "$VTOKEN" "$STATE_DIR/app2" "$STATE_DIR/app2.tar" > "$STATE_DIR/app2.json"
python3 "$STATE_DIR/mkimg.py" "$PAUSE_REF" "pause" "$STATE_DIR/pause" "$STATE_DIR/pause.tar" > "$STATE_DIR/pause.json"

echo "[setup] the registry (plain HTTP on $REG_HOST; every request is logged; the repositories below $PRIVATE/ and /v2/ itself need Basic authentication,"
echo "[setup] the sandbox image's repository is anonymous), then the three images pushed with the distribution API..."
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
AUTH_USER, AUTH_PASS, PRIVATE = sys.argv[5], sys.argv[6], sys.argv[7]   # every request for a repository below PRIVATE/ needs Basic authentication; /v2/ itself too (it carries the challenge)
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
        if path in ("/v2/", "/v2") or path.startswith("/v2/" + PRIVATE + "/"):
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
S(("127.0.0.1", port), H).serve_forever()
PYEOF
sudo install -m 0644 "$STATE_DIR/registry.py" "$REG_DIR/registry.py"
start_daemon "$RUN_BASE/registry.pid" "$RUN_BASE/registry.log" python3 "$REG_DIR/registry.py" "$REG_DIR" "$REG_PORT" "$REG_DIR/requests.log" "$ORG" "$REG_USER" "$REG_PASS" "$PRIVATE"
for _ in $(seq 1 40); do curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$REG_PORT/v2/" && break; sleep 0.25; done
curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$REG_PORT/v2/" || { echo "[setup] ERROR: the registry did not come up"; sudo tail -5 "$RUN_BASE/registry.log"; exit 1; }
cat > "$STATE_DIR/push.py" <<'PYEOF'
import base64, http.client, json, sys, tarfile
tarp, meta, port, repo, tag, user, pw = sys.argv[1:8]
m = json.load(open(meta)); t = tarfile.open(tarp)
H = {"Authorization": "Basic " + base64.b64encode((user + ":" + pw).encode()).decode()}
def blob(d): return t.extractfile("blobs/sha256/" + d.split(":")[1]).read()
def req(method, path, body=None, hdr=None):
    c = http.client.HTTPConnection("127.0.0.1", int(port)); c.request(method, path, body=body, headers=dict(H, **(hdr or {}))); r = c.getresponse(); r.read(); return r.status
for d in (m["config"], m["layer"]):
    s = req("POST", "/v2/%s/blobs/uploads/?digest=%s" % (repo, d), blob(d), {"Content-Type": "application/octet-stream"})
    assert s in (201, 202), "blob upload: HTTP %d" % s
s = req("PUT", "/v2/%s/manifests/%s" % (repo, tag), blob(m["manifest"]), {"Content-Type": m["media_type"]})
assert s == 201, "manifest put: HTTP %d" % s
PYEOF
python3 "$STATE_DIR/push.py" "$STATE_DIR/app.tar" "$STATE_DIR/app.json" "$REG_PORT" "$REPO" "$TAG" "$REG_USER" "$REG_PASS" || { echo "[setup] ERROR: could not push the application image"; exit 1; }
python3 "$STATE_DIR/push.py" "$STATE_DIR/app2.tar" "$STATE_DIR/app2.json" "$REG_PORT" "$REPO" "$VTAG" "$REG_USER" "$REG_PASS" || { echo "[setup] ERROR: could not push the second image"; exit 1; }
python3 "$STATE_DIR/push.py" "$STATE_DIR/pause.tar" "$STATE_DIR/pause.json" "$REG_PORT" "$ORG/pause" 1 "$REG_USER" "$REG_PASS" || { echo "[setup] ERROR: could not push the sandbox image"; exit 1; }
MANIFEST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/app.json")
VMANIFEST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/app2.json")
CONFIGD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"])' "$STATE_DIR/app.json")
LAYERD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["layer"])' "$STATE_DIR/app.json")
VCONFIGD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"])' "$STATE_DIR/app2.json")
VLAYERD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["layer"])' "$STATE_DIR/app2.json")
echo "  -> anonymous: $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$REG_PORT/v2/$REPO/manifests/$TAG") for the private repository, $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$REG_PORT/v2/$ORG/pause/manifests/1") for the sandbox image; with the credentials: $(curl -s -o /dev/null -w '%{http_code}' -u "$REG_USER:$REG_PASS" "http://127.0.0.1:$REG_PORT/v2/$REPO/manifests/$TAG")"

echo "[setup] the network stub for the node (two CNI plugins that only answer: no bridge, no iptables, nothing on the host's network)..."
cat <<'CEOF' | sudo tee "$LIB_BASE/cni/bin/loopback" >/dev/null
#!/bin/bash
case "$CNI_COMMAND" in
    ADD) echo '{"cniVersion":"1.0.0","interfaces":[{"name":"lo","sandbox":"'"$CNI_NETNS"'"}],"ips":[{"address":"127.0.0.1/8","interface":0}]}' ;;
    VERSION) echo '{"cniVersion":"1.0.0","supportedVersions":["0.3.0","0.3.1","0.4.0","1.0.0","1.1.0"]}' ;;
    *) ;;
esac
CEOF
cat <<'CEOF' | sudo tee "$LIB_BASE/cni/bin/benchnet" >/dev/null
#!/bin/bash
case "$CNI_COMMAND" in
    ADD) echo '{"cniVersion":"1.0.0","interfaces":[{"name":"'"$CNI_IFNAME"'","sandbox":"'"$CNI_NETNS"'"}],"ips":[{"address":"10.88.0.2/16","interface":0}]}' ;;
    VERSION) echo '{"cniVersion":"1.0.0","supportedVersions":["0.3.0","0.3.1","0.4.0","1.0.0","1.1.0"]}' ;;
    *) ;;
esac
CEOF
sudo chmod 755 "$LIB_BASE/cni/bin/loopback" "$LIB_BASE/cni/bin/benchnet"
echo '{"cniVersion":"1.0.0","name":"benchnet","plugins":[{"type":"benchnet"}]}' | sudo tee "$LIB_BASE/cni/net.d/10-benchnet.conflist" >/dev/null

echo "[setup] which OCI runtime and monitor (conmon) the machine's CRI-O uses by default, from 'crio config'; the private CRI-O uses the same ones..."
CFG=$(sudo crio config 2>/dev/null)
# 'crio config' prints the built-in default as a comment ("# default_runtime = "crun""): an uncommented line (a drop-in) wins, else the commented one is the value in force
DEF=$(echo "$CFG" | awk -F'"' '/^[[:space:]]*default_runtime[[:space:]]*=/ {print $2; exit}')
[ -n "$DEF" ] || DEF=$(echo "$CFG" | awk -F'"' '/^#[[:space:]]*default_runtime[[:space:]]*=/ {print $2; exit}')
DEF=${DEF:-runc}
tbl() { echo "$CFG" | awk -v t="[crio.runtime.runtimes.$DEF]" -v k="$1" '$0 == t {on=1; next} /^\[/ {on=0} on && $1 == k {gsub(/"/, "", $3); print $3; exit}'; }
BACKEND=$(tbl runtime_path); MONITOR=$(tbl monitor_path)
[ -x "$BACKEND" ] || BACKEND=$(command -v runc || true)
[ -x "$MONITOR" ] || MONITOR=$(command -v conmon || echo /usr/libexec/crio/conmon)
[ -x "$BACKEND" ] || { echo "[setup] ERROR: no OCI runtime found for CRI-O's default runtime '$DEF'"; exit 1; }
PINNS=$(echo "$CFG" | awk -F'"' '/^#?[[:space:]]*pinns_path[[:space:]]*=/ {print $2; exit}')
[ -x "$PINNS" ] || PINNS=$(command -v pinns || echo /usr/libexec/crio/pinns)
echo "  -> default runtime '$DEF': $BACKEND, conmon $MONITOR, pinns $PINNS"

echo "[setup] the private CRI-O: own socket $CRIO_SOCK, storage, run root, CNI directories (the stub), the sandbox image from the registry, the registry's loopback address allowed over"
echo "[setup] plain HTTP, no credentials of any kind (no global auth file), no NRI..."
echo '{"default":[{"type":"insecureAcceptAnything"}]}' | sudo tee "$LIB_BASE/crio/policy.json" >/dev/null
sudo mkdir -p "$RUN_BASE/crio"
sudo tee "$LIB_BASE/crio/crio.conf" >/dev/null <<EOF
[crio]
root = "$LIB_BASE/crio/root"
runroot = "$RUN_BASE/crio"
storage_driver = "overlay"
log_dir = "$LIB_BASE/crio/pods"
version_file = "$RUN_BASE/crio/version"
version_file_persist = ""
clean_shutdown_file = "$LIB_BASE/crio/clean.shutdown"

[crio.api]
listen = "$CRIO_SOCK"

[crio.runtime]
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
default_runtime = "bench"
container_exits_dir = "$RUN_BASE/crio/exits"
container_attach_socket_dir = "$RUN_BASE/crio"
namespaces_dir = "$RUN_BASE/crio/ns"
pinns_path = "$PINNS"

[crio.runtime.runtimes.bench]
runtime_path = "$BACKEND"
runtime_root = "$RUN_BASE/runtime"
monitor_path = "$MONITOR"

[crio.image]
pause_image = "$PAUSE_REF"
pause_command = "/app"
signature_policy = "$LIB_BASE/crio/policy.json"
insecure_registries = ["$REG_HOST"]

[crio.network]
network_dir = "$LIB_BASE/cni/net.d"
plugin_dirs = ["$LIB_BASE/cni/bin"]

[crio.nri]
enable_nri = false
EOF
start_daemon "$RUN_BASE/crio.pid" "$RUN_BASE/crio.log" env HOME=/root crio --config "$LIB_BASE/crio/crio.conf" --config-dir "" --log-level info
for _ in $(seq 1 60); do
    [ -S "$CRIO_SOCK" ] && $CRICTL version >/dev/null 2>&1 && break
    sleep 0.5
done
$CRICTL version >/dev/null 2>&1 || { echo "[setup] ERROR: the private CRI-O did not come up; last log lines:"; sudo tail -15 "$RUN_BASE/crio.log" | cut -c1-250; exit 1; }
$CRICTL pull "$PAUSE_REF" >/dev/null 2>&1 || { echo "[setup] ERROR: CRI-O could not pull the sandbox image anonymously"; sudo tail -5 "$RUN_BASE/crio.log" | cut -c1-250; exit 1; }
echo "  -> CRI-O $($CRICTL version 2>/dev/null | awk '/RuntimeVersion/ {print $2}') up on $CRIO_SOCK; its store holds only the sandbox image"

echo "[setup] writing the Kubernetes (k3s) configuration $K3S_CONFIG, with this CRI-O as its runtime, and the script that starts and stops k3s..."
sudo mkdir -p /etc/rancher/k3s
cat <<CEOF | sudo tee "$K3S_CONFIG" >/dev/null
# configuration of the Kubernetes of this machine
data-dir: $LIB_BASE/k3s
https-listen-port: 16443
node-name: $NODE
container-runtime-endpoint: unix://$CRIO_SOCK
# a small single node: no add-ons, no kube-proxy, nothing that touches the host's network
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
  - cgroup-driver=cgroupfs
  - cgroups-per-qos=false
  - enforce-node-allocatable=
  - make-iptables-util-chains=false
CEOF
cat <<CEOF | sudo tee "$CTL_DIR/k3sctl" >/dev/null
#!/bin/bash
# how k3s is started and stopped on this machine: k3sctl start|stop|restart|status
# (k3s reads its options from $K3S_CONFIG)
PIDF="$RUN_BASE/k3s.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "k3s is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec "\$2" server >>"\$3" 2>&1 </dev/null' _ "\$PIDF" "$K3S_BIN" "$RUN_BASE/k3s.log" </dev/null >/dev/null 2>&1
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

echo "[setup] starting k3s. Waiting for the node $NODE to be Ready..."
sudo "$CTL_DIR/k3sctl" start >/dev/null
K="sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml K3S_DATA_DIR=$LIB_BASE/k3s $K3S_BIN kubectl"
READY=""
for _ in $(seq 1 60); do
    READY=$($K get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ "$READY" = "True" ] && break
    sleep 2
done
if [ "$READY" != "True" ]; then
    echo "[setup] ERROR: the node $NODE did not become Ready; last log lines of k3s:"
    sudo tail -5 "$RUN_BASE/k3s.log" 2>/dev/null | cut -c1-200
    exit 1
fi
echo "  -> node $NODE Ready, container runtime $($K get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')"

echo "[setup] the job's files: the pod manifest, the wrappers k (kubectl of this Kubernetes) and node-crictl (crictl against the node's CRI-O)..."
cat > "$WORK_DIR/pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: app
  namespace: default
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $REF
EOF
chmod 644 "$WORK_DIR/pod.yaml"
cat > "$WORK_DIR/bin/k" <<EOF
#!/bin/sh
# k ARGS...: kubectl of this machine's Kubernetes (run it as the current user; it calls sudo itself)
exec sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml K3S_DATA_DIR=$LIB_BASE/k3s $K3S_BIN kubectl "\$@"
EOF
cat > "$WORK_DIR/bin/node-crictl" <<EOF
#!/bin/sh
# node-crictl ARGS...: crictl against the node's CRI-O (the container runtime of the kubelet)
exec sudo crictl --runtime-endpoint unix://$CRIO_SOCK --image-endpoint unix://$CRIO_SOCK "\$@"
EOF
chmod 755 "$WORK_DIR/bin/k" "$WORK_DIR/bin/node-crictl"

echo "[setup] the engineer's first attempt: the pod of pod.yaml, without any credentials..."
for _ in $(seq 1 30); do
    $K get serviceaccount default >/dev/null 2>&1 && break
    sleep 1
done
$K apply -f "$WORK_DIR/pod.yaml" >/dev/null || { echo "[setup] ERROR: could not create the pod"; exit 1; }
STATE=""
for _ in $(seq 1 90); do
    STATE=$($K get pod app -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
    case "$STATE" in ErrImagePull|ImagePullBackOff) break ;; esac
    sleep 2
done
case "$STATE" in
    ErrImagePull|ImagePullBackOff) echo "  -> the pod app: $STATE" ;;
    *) echo "[setup] ERROR: the pod did not reach ErrImagePull (state '$STATE')"; $K get pods -A 2>&1 | head; sudo tail -5 "$RUN_BASE/k3s.log" | cut -c1-200; exit 1 ;;
esac

echo "[setup] recording the state (root-only): the daemons (pid + start time + program), hashes of the programs, scripts and configuration, the credentials, the images' digests..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" REG_DIR="$REG_DIR" CTL_DIR="$CTL_DIR" \
    REG_HOST="$REG_HOST" REPO="$REPO" TAG="$TAG" VTAG="$VTAG" REF="$REF" PRIVATE="$PRIVATE" ORG="$ORG" REG_USER="$REG_USER" REG_PASS="$REG_PASS" \
    TOKEN="$TOKEN" VTOKEN="$VTOKEN" MANIFEST="$MANIFEST" VMANIFEST="$VMANIFEST" CONFIGD="$CONFIGD" LAYERD="$LAYERD" VCONFIGD="$VCONFIGD" VLAYERD="$VLAYERD" \
    CRIO_SOCK="$CRIO_SOCK" K3S_BIN="$K3S_BIN" NODE="$NODE" python3 - <<'PYEOF'
import hashlib, json, os
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def ident(name):
    pid = int(open("%s/%s.pid" % (E["RUN_BASE"], name)).read())
    s = open("/proc/%d/stat" % pid).read()
    return [pid, int(s[s.rindex(")") + 2:].split()[19]), os.readlink("/proc/%d/exe" % pid)]
files = [E["REG_DIR"] + "/registry.py", E["LIB_BASE"] + "/crio/crio.conf", E["LIB_BASE"] + "/crio/policy.json", "/etc/rancher/k3s/config.yaml",
         E["CTL_DIR"] + "/k3sctl", E["WORK_DIR"] + "/bin/k", E["WORK_DIR"] + "/bin/node-crictl", E["WORK_DIR"] + "/registry.cred"]
d = {"daemons": {n: ident(n) for n in ("crio", "k3s", "registry")}, "files": {f: sha(f) for f in files},
     "registry_state": sha(E["REG_DIR"] + "/state.json"), "registry_lines": sum(1 for _ in open(E["REG_DIR"] + "/requests.log")),
     "reg_host": E["REG_HOST"], "repo": E["REPO"], "tag": E["TAG"], "vtag": E["VTAG"], "ref": E["REF"], "private": E["PRIVATE"],
     "user": E["REG_USER"], "password": E["REG_PASS"], "token": E["TOKEN"], "vtoken": E["VTOKEN"], "crio_sock": E["CRIO_SOCK"], "k3s_bin": E["K3S_BIN"], "node": E["NODE"],
     "image": {"manifest": E["MANIFEST"], "config": E["CONFIGD"], "layer": E["LAYERD"]},
     "vimage": {"manifest": E["VMANIFEST"], "config": E["VCONFIGD"], "layer": E["VLAYERD"]}}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR"/app "$STATE_DIR"/app2 "$STATE_DIR"/app.c "$STATE_DIR"/pause "$STATE_DIR"/pause.c "$STATE_DIR"/*.tar "$STATE_DIR"/app.json "$STATE_DIR"/app2.json "$STATE_DIR"/pause.json \
    "$STATE_DIR"/mkimg.py "$STATE_DIR"/push.py "$STATE_DIR"/registry.py "$STATE_DIR"/tokens
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. The registry holds $REPO:$TAG (credentials in $WORK_DIR/registry.cred); the pod app asks for $REF and does not run."
