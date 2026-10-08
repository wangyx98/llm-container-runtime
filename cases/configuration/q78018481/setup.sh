#!/bin/bash
set -e

CASE_ID="bench78018481"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files and logs of containerd and of the two registries
LIB_BASE="/var/lib/$CASE_ID"          # containerd root, control scripts (not in /run: it is mounted noexec on many hosts)
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
OLD_PORT=18081                        # the registry the sandbox ("pause") image comes from at the start
NEW_PORT=18082                        # the registry it must come from afterwards
OLD_DIR="$RUN_BASE/registry-old"
NEW_DIR="$RUN_BASE/registry-new"
REPO="google_containers/pause"
TAG="3.6"
OLD_REF="127.0.0.1:$OLD_PORT/$REPO:$TAG"
NEW_REF="127.0.0.1:$NEW_PORT/$REPO:$TAG"

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
for b in containerd ctr runc curl python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking ports $OLD_PORT and $NEW_PORT are free..."
for p in $OLD_PORT $NEW_PORT; do
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

echo "[setup] making sure gcc is available (gcc: the two tiny static programs that are the only files of the two"
echo "[setup] images, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR" "$OLD_DIR" "$NEW_DIR"
cd "$WORK_DIR"

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of
# the daemon itself (exec keeps the pid); setsid + all three fds redirected so it outlives this
# script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] building the two pause images offline, in DOCKER format (what docker push sends): both are valid"
echo "[setup] pause images (a static program that only waits), but not the same bytes: each carries its own label,"
echo "[setup] so they have different digests..."
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <unistd.h>

/* the label makes the binary, so the layer and the image digest, differ between the two registries */
static const char label[] __attribute__((used)) = "bench78018481-pause-from-" LABEL;

int main(void) {
    for (;;) pause();
}
CEOF
gcc -static -Os -s -w -DLABEL='"old"' -o "$STATE_DIR/pause-old" "$STATE_DIR/pause.c"
gcc -static -Os -s -w -DLABEL='"new"' -o "$STATE_DIR/pause-new" "$STATE_DIR/pause.c"
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
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": ctype,
                                                                         "User-Agent": "docker/20.10.21 (setup)"})
    with urllib.request.urlopen(req, timeout=30) as r:
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
cat > "$STATE_DIR/registry.py" <<'PYEOF'
"""A minimal, read-write OCI/Docker distribution registry (HTTP, no auth) for the case.

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
import sys
import threading
import urllib.parse
import uuid

root, port, logfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
org = sys.argv[4] if len(sys.argv) > 4 else ""
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


save_state()
S(("127.0.0.1", port), H).serve_forever()
PYEOF

echo "[setup] starting the two registries (plain HTTP, no authentication, every request logged with its"
echo "[setup] User-Agent): the OLD one on 127.0.0.1:$OLD_PORT, the NEW one on 127.0.0.1:$NEW_PORT..."
for w in old new; do
    if [ "$w" = old ]; then D="$OLD_DIR"; P=$OLD_PORT; else D="$NEW_DIR"; P=$NEW_PORT; fi
    sudo cp "$STATE_DIR/registry.py" "$D/registry.py"
    sudo touch "$D/requests.log"
    start_daemon "$D/registry.pid" "$D/registry.out" python3 "$D/registry.py" "$D" "$P" "$D/requests.log"
    for _ in $(seq 1 40); do
        curl -sf --max-time 2 "http://127.0.0.1:$P/v2/" >/dev/null 2>&1 && break
        sleep 0.25
    done
    curl -sf --max-time 2 "http://127.0.0.1:$P/v2/" >/dev/null \
        || { echo "[setup] ERROR: the $w registry did not come up"; sudo tail -5 "$D/registry.out" 2>/dev/null; exit 1; }
    python3 "$STATE_DIR/mkimg.py" push "http://127.0.0.1:$P" "$REPO" "$TAG" "$STATE_DIR/pause-$w" pause > "$STATE_DIR/$w.truth" \
        || { echo "[setup] ERROR: could not push the pause image to the $w registry"; exit 1; }
    echo "  -> $w registry up on 127.0.0.1:$P, holds $REPO:$TAG = $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/$w.truth")"
done
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/old.truth")" \
    != "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/new.truth")" ] \
    || { echo "[setup] ERROR: the two pause images have the same digest"; exit 1; }

echo "[setup] starting the pre-installed containerd (the runtime of this machine: own socket, root, state and"
echo "[setup] image/content store; containerd's own default config for the installed version, moved into that"
echo "[setup] root/state, NRI off; its sandbox image is the OLD one)..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock, cni, pause = sys.argv[1:6]
section = ""
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
    sys.stdout.write(line)
PYEOF
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" "$LIB_BASE/cni" "$OLD_REF" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
grep -qF "$OLD_REF" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
# Both registries speak plain HTTP, and the CRI needs to be told so: a per-registry configuration directory of
# the case (not /etc/containerd/certs.d) names them, so that containerd can pull the pause image from either.
sudo python3 - "$RUN_BASE/config.toml" "$LIB_BASE/certs.d" <<'PY'
import re, sys
path, certs = sys.argv[1:3]
out, section, done = [], "", False
for line in open(path):
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    if section.endswith(".registry") and "cri" in section and re.match(r"^\s*config_path\s*=", line):
        line = re.sub(r"=.*", "= '%s'" % certs, line) + "\n"
        done = True
    out.append(line)
if not done:
    sys.exit("no CRI registry config_path found in the containerd config")
open(path, "w").writelines(out)
PY
for p in $OLD_PORT $NEW_PORT; do
    sudo mkdir -p "$LIB_BASE/certs.d/127.0.0.1:$p"
    sudo tee "$LIB_BASE/certs.d/127.0.0.1:$p/hosts.toml" >/dev/null <<CONF
server = "http://127.0.0.1:$p"

[host."http://127.0.0.1:$p"]
  capabilities = ["pull", "resolve"]
CONF
done
cat <<CEOF | sudo tee "$CTL_DIR/containerdctl" >/dev/null
#!/bin/bash
# how this machine's containerd is started and stopped: containerdctl start|stop|restart|status
PIDF="$RUN_BASE/containerd.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "containerd is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec containerd --config "\$2" >"\$3" 2>&1 </dev/null' _ "\$PIDF" "$RUN_BASE/config.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
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

echo "[setup] the first sandbox of this machine, as an existing workload: a pod (host network) whose sandbox runs"
echo "[setup] the OLD pause image, pulled from the OLD registry..."
cat > "$WORK_DIR/old-pod.json" <<CONF
{
  "metadata": {"name": "bench78018481-old", "namespace": "default", "attempt": 1, "uid": "bench78018481-old-uid"},
  "log_directory": "$WORK_DIR/logs",
  "linux": {"security_context": {"namespace_options": {"network": 2}}}
}
CONF
mkdir -p "$WORK_DIR/logs"
OLD_POD=$("${CRI[@]}" runp "$WORK_DIR/old-pod.json" 2> "$STATE_DIR/old-runp.err") \
    || { echo "[setup] ERROR: could not start the first sandbox:"; tail -3 "$STATE_DIR/old-runp.err" | cut -c1-300; exit 1; }
echo "$OLD_POD" > "$STATE_DIR/old-pod.id"
echo "  -> pod bench78018481-old, sandbox $OLD_POD"

echo "[setup] recording the identity of the daemons (pid + start time) and the content of the registries..."
P=$(cat "$RUN_BASE/containerd.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
for w in old new; do
    D="$RUN_BASE/registry-$w"
    P=$(cat "$D/registry.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/registry-$w.id"
    cp "$D/state.json" "$STATE_DIR/registry-$w.state0"
done
sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}' > "$STATE_DIR/containerdctl.sha"

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/pause.c" "$STATE_DIR/pause-old" "$STATE_DIR/pause-new" "$STATE_DIR/mkimg.py" \
    "$STATE_DIR/patch_config.py" "$STATE_DIR/registry.py" "$STATE_DIR/old-runp.err"

echo "[setup] done. containerd's sandbox image is $OLD_REF; $NEW_REF holds another valid pause image."
