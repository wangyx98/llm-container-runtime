#!/bin/bash
set -e

CASE_ID="bench62439583"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"
ETC="$LIB/etc"                                   # the node's configuration: containerd.toml (and, if the solution wants one, a hosts directory)
COMMON="$LIB/common"                             # containerd's root, state, socket and log
BIN="$LIB/bin"                                   # nodectl (root-owned; not in /run: it is mounted noexec on many hosts)
SOCK="$COMMON/run/containerd.sock"
RUN="/run/$CASE_ID"                              # the logs of the JFrog stand-in and the stores of the two upstreams
STORE_DOCKER="$RUN/store-docker-hub"             # the images of the Docker Hub stand-in (blobs, tags.json)
STORE_QUAY="$RUN/store-quay"                     # the images of the Quay stand-in
ADDR_DOCKER="127.62.43.95"                       # JFrog repository `docker` (virtual: docker-remote), like https://docker.jcr.mydomain
ADDR_QUAY="127.62.43.96"                         # JFrog repository `quay-remote` (remote repository of Quay), like https://quay.jcr.mydomain
ADDR_UP_DOCKER="127.62.43.97"                    # the "public" Docker Hub the first one caches
ADDR_UP_QUAY="127.62.43.98"                      # the "public" Quay the second one caches
PORT=8082
UPORT=5000
WEB_REPO="benchlab62439/web"                     # the image of the team on Docker Hub (also pulled under the name k8s.gcr.io/...)
FLANNEL_REPO="benchlab62439/flannel"                    # the image on Quay
FLANNEL_TAG="v0.11.0-amd64"
PAUSE_REF="$CASE_ID.local/pause:1"               # the sandbox image of the pods, imported offline
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): the lab's programs and their hashes

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking the tools: containerd (2.x), ctr, runc, python3, curl, sudo..."
for c in containerd ctr runc python3 curl sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
CTD_VER=$(containerd --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)     # "containerd github.com/containerd/containerd/v2 v2.2.1 ..." or "containerd containerd.io 2.2.1 ..." (Docker's package)
[ "${CTD_VER%%.*}" -ge 2 ] 2>/dev/null || { echo "[setup] ERROR: containerd 2.x is needed (the configuration of the lab is the one of version 3 and 4), found: $(containerd --version)"; exit 1; }
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
containerd --version
crictl --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (two tiny static programs, so nothing has to be pulled from a public registry)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] checking that $ADDR_DOCKER:$PORT, $ADDR_QUAY:$PORT, $ADDR_UP_DOCKER:$UPORT and $ADDR_UP_QUAY:$UPORT are free..."
python3 - "$ADDR_DOCKER:$PORT" "$ADDR_QUAY:$PORT" "$ADDR_UP_DOCKER:$UPORT" "$ADDR_UP_QUAY:$UPORT" <<'PYEOF' || { echo "[setup] ERROR: something already listens on one of those addresses"; exit 1; }
import socket, sys
for hp in sys.argv[1:]:
    host, port = hp.split(":")
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)     # sockets in TIME_WAIT of a previous run do not count; a listener does
    try:
        s.bind((host, int(port)))
    except OSError:
        sys.exit(1)
    s.close()
PYEOF

echo "[setup] resetting the work dir; the lab's programs go where only root can change them..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

echo "[setup] writing the lab's programs (the JFrog stand-in with the two upstreams, the containerd configuration patch, nodectl, two tiny programs)..."
sudo tee "$STATE_DIR/jcr.py" >/dev/null <<'JCR_PY_EOF'
#!/usr/bin/env python3
"""jcr.py serve ...    : the lab's stand-in for a JFrog Container Registry: two repositories, each on an address of its own (the "port method" of Artifactory's reverse proxy; Docker API v2 at the root of
                         the address), in front of two stand-ins for the public registries they cache (an "upstream" for Docker Hub, an "upstream" for Quay):
                           docker       virtual repository (members: docker-remote, the cache of the Docker Hub stand-in)   readable by the account ci only
                           quay-remote  remote repository (the cache of the Quay stand-in)                                   readable by the account quay-reader only
   jcr.py publish STORE REPO TAG BINARY ENTRY [SALT] : put a new image build (one layer with BINARY as /ENTRY and a file /salt) into the store of an upstream; prints its digests as JSON
   jcr.py tar OUT REF BINARY ENTRY                    : the same kind of image as an OCI archive (for ctr images import)

The rules of the repositories (Artifactory's, as far as the lab needs them): HTTP Basic authentication; a request without credentials, or with wrong ones, gets 401 and the challenge
'Basic realm="Artifactory Realm"'; valid credentials of an account that has no permission on the repository get 403 Forbidden; a repository that does not hold the image gets 404 (the virtual
repository `docker` looks in its members only). The repositories read the upstreams as clients named jcr-lab/1; the upstreams answer anybody. One JSON line per request in the logs."""
import base64
import gzip
import hashlib
import hmac
import http.client
import io
import json
import os
import re
import sys
import tarfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"
ARCH = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
PERMISSIONS = {"docker": {"ci"}, "quay-remote": {"quay-reader"}}
CLIENT = "jcr-lab/1"


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def build(binary, entry, salt=""):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data, mode in ((entry, open(binary, "rb").read(), 0o755), ("salt", (salt + "\n").encode() if salt else None, 0o644)):
            if data is None:
                continue
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname = len(data), mode, 1700000000, 0, 0, "", ""
            t.addfile(ti, io.BytesIO(data))
    layer = buf.getvalue()
    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
        g.write(layer)
    layer_gz = gz.getvalue()
    config = json.dumps({"architecture": ARCH, "os": "linux", "created": "2023-11-14T22:13:20Z",
                         "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], "Entrypoint": ["/" + entry], "Cmd": [], "WorkingDir": "/"},
                         "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY %s /" % entry}],
                         "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}, separators=(",", ":")).encode()
    manifest = json.dumps({"schemaVersion": 2, "mediaType": DOCKER_MANIFEST,
                           "config": {"mediaType": DOCKER_CONFIG, "digest": sha(config), "size": len(config)},
                           "layers": [{"mediaType": DOCKER_LAYER, "digest": sha(layer_gz), "size": len(layer_gz)}]}, separators=(",", ":")).encode()
    return layer_gz, config, manifest


def truth(layer_gz, config, manifest):
    return json.dumps({"manifest": sha(manifest), "config": sha(config), "layer": sha(layer_gz)})


def publish(d, repo, tag, binary, entry, salt):
    layer_gz, config, manifest = build(binary, entry, salt)
    os.makedirs(os.path.join(d, "blobs"), exist_ok=True)
    for b in (layer_gz, config, manifest):
        with open(os.path.join(d, "blobs", sha(b).split(":")[1]), "wb") as f:
            f.write(b)
    tags = {}
    try:
        tags = json.load(open(os.path.join(d, "tags.json")))
    except (OSError, ValueError):
        pass
    tags["%s:%s" % (repo, tag)] = sha(manifest)
    tmp = os.path.join(d, ".tags.tmp")
    json.dump(tags, open(tmp, "w"))
    os.replace(tmp, os.path.join(d, "tags.json"))
    print(truth(layer_gz, config, manifest))


def make_tar(out, ref, binary, entry):
    layer_gz, config, manifest = build(binary, entry)
    index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": DOCKER_MANIFEST, "digest": sha(manifest), "size": len(manifest),
                        "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
    with tarfile.open(out, "w") as t:
        for name, data in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(layer_gz).split(":")[1], layer_gz),
                           ("blobs/sha256/" + sha(config).split(":")[1], config), ("blobs/sha256/" + sha(manifest).split(":")[1], manifest)):
            ti = tarfile.TarInfo(name)
            ti.size, ti.mtime = len(data), 1700000000
            t.addfile(ti, io.BytesIO(data))
    print(truth(layer_gz, config, manifest))


V2 = re.compile(r"^/v2/(.+)/(manifests|blobs)/([^/]+)$")
NOT_FOUND = b'{"errors":[{"code":"MANIFEST_UNKNOWN","message":"not found"}]}'


def serve(args):
    addr_docker, addr_quay, addr_up_docker, addr_up_quay, port, uport, store_docker, store_quay, accounts_json, jcr_log, up_log = args
    port, uport = int(port), int(uport)
    accounts = json.load(open(accounts_json))
    lock = threading.Lock()
    logs = {"jcr": open(jcr_log, "a", buffering=1), "up": open(up_log, "a", buffering=1)}

    def record(which, **kw):
        kw["t"] = round(time.time(), 3)
        with lock:
            logs[which].write(json.dumps(kw, sort_keys=True) + "\n")

    class Base(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "jcr-lab"

        def log_message(self, *a):
            pass

        def send(self, code, body=b"", ctype="application/json", extra=None, head=False):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def ranged(self, code, data, ctype, extra, head):
            rng = re.match(r"bytes=(\d+)-(\d*)$", self.headers.get("Range", ""))
            if rng and code == 200 and not head and "blobs" in self.path:
                a = int(rng.group(1))
                b = int(rng.group(2)) if rng.group(2) else len(data) - 1
                extra = dict(extra, **{"Content-Range": "bytes %d-%d/%d" % (a, b, len(data))})
                return 206, data[a:b + 1], ctype, extra
            return code, data, ctype, extra

    def upstream_handler(label, store):
        class Upstream(Base):
            def dispatch(self, head):
                path = urlparse(self.path).path
                m = V2.match(path)
                ua = self.headers.get("User-Agent", "")
                code, body, ctype, extra = 404, NOT_FOUND, "application/json", {}
                if path in ("/v2/", "/v2"):
                    code, body = 200, b"{}"
                elif m:
                    repo, kind, ref = m.groups()
                    try:
                        digest = ref if ref.startswith("sha256:") else json.load(open(os.path.join(store, "tags.json")))["%s:%s" % (repo, ref)]
                        data = open(os.path.join(store, "blobs", digest.split(":")[1]), "rb").read()
                        ctype = json.loads(data).get("mediaType", DOCKER_MANIFEST) if kind == "manifests" else "application/octet-stream"
                        code, body, extra = 200, data, {"Docker-Content-Digest": digest}
                    except (OSError, ValueError, KeyError, IndexError):
                        pass
                code, body, ctype, extra = self.ranged(code, body, ctype, extra, head)
                self.send(code, body, ctype, extra, head)
                record("up", srv=label, method=self.command, path=path, status=code, ua=ua)

            def do_GET(self):
                self.dispatch(False)

            def do_HEAD(self):
                self.dispatch(True)
        return Upstream

    def repo_handler(repo, up_addr):
        class Repo(Base):
            def dispatch(self, head):
                path = urlparse(self.path).path
                h = self.headers.get("Authorization", "")
                user, state = "-", "none"
                if h.lower().startswith("basic "):
                    state = "basic"
                    try:
                        u, p = base64.b64decode(h.split(None, 1)[1]).decode().split(":", 1)
                    except Exception:                                   # noqa: BLE001
                        u, p = "", ""
                    user = u if (u in accounts and hmac.compare_digest(p, accounts[u])) else "rejected"
                elif h:
                    state, user = "other", "rejected"
                m = V2.match(path)

                def done(code, body=b"", ctype="application/json", extra=None):
                    self.send(code, body, ctype, extra, head)
                    record("jcr", repo=repo, method=self.command, path=path, auth=state, who=user, status=code, ua=self.headers.get("User-Agent", ""))

                if user in ("-", "rejected"):
                    return done(401, b'{"errors":[{"status":401,"message":"Bad credentials"}]}', extra={"WWW-Authenticate": 'Basic realm="Artifactory Realm"'})
                if path in ("/v2/", "/v2"):
                    return done(200, b"{}")
                if user not in PERMISSIONS[repo]:
                    return done(403, json.dumps({"errors": [{"status": 403, "message": "Forbidden: %s is not permitted to read %s" % (user, repo)}]}).encode())
                if not m:
                    return done(404, NOT_FOUND)
                c = http.client.HTTPConnection(up_addr, uport, timeout=10)
                c.request("GET", path, headers={"User-Agent": CLIENT})
                r = c.getresponse()
                data = r.read()
                c.close()
                if r.status != 200:
                    return done(404, NOT_FOUND)
                extra = {"Docker-Content-Digest": r.getheader("Docker-Content-Digest", "")}
                code, data, ctype, extra = self.ranged(200, data, r.getheader("Content-Type", "application/octet-stream"), extra, head)
                return done(code, data, ctype, extra)

            def do_GET(self):
                self.dispatch(False)

            def do_HEAD(self):
                self.dispatch(True)
        return Repo

    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer.allow_reuse_address = True
    servers = [ThreadingHTTPServer((addr_up_docker, uport), upstream_handler("docker-hub", store_docker)),
               ThreadingHTTPServer((addr_up_quay, uport), upstream_handler("quay", store_quay)),
               ThreadingHTTPServer((addr_docker, port), repo_handler("docker", addr_up_docker)),
               ThreadingHTTPServer((addr_quay, port), repo_handler("quay-remote", addr_up_quay))]
    for s in servers[:-1]:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    servers[-1].serve_forever()


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "serve":
        serve(sys.argv[2:13])
    elif mode == "publish":
        publish(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7] if len(sys.argv) > 7 else "")
    elif mode == "tar":
        make_tar(*sys.argv[2:6])
JCR_PY_EOF
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'PATCH_PY_EOF'
"""patch_config.py LIB RUN SOCK CNI PAUSE < default.toml > template.toml : containerd's default configuration of the installed version (config version 3 of containerd 2.0-2.2 or 4 of 2.3)
turned into the node's STOCK TEMPLATE: root, state, socket, CNI directories and the runc runtime root are the strings given (the lab passes ${SNAP_COMMON}/... and ${SNAP_DATA}/... as
literal text, which the node's launcher replaces at every start), NRI off, a local sandbox image, runc on the cgroupfs driver, and no registry setting at all (config_path forced
to '' because the default of some versions is not empty)."""
import re
import sys

lib, run, sock, cni, pause = sys.argv[1:6]
section = ""
runc_options = False
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
        runc_options = section.endswith(".runtimes.runc.options")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    grpc = section == "grpc" or section.endswith("server.v1.grpc")
    ttrpc = section == "ttrpc" or section.endswith("server.v1.ttrpc")
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}'\n"
    elif grpc and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif ttrpc and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        # do not require CAP_SYS_RESOURCE (absent in unprivileged or nested environments)
        line = f"{indent}restrict_oom_score_adj = true\n"
    elif section.endswith(".cni") and k == "bin_dirs":
        line = f"{indent}bin_dirs = ['{cni}/bin']\n"
    elif section.endswith(".cni") and k == "bin_dir" and not re.search(r"=\s*(''|\"\")\s*$", line):
        line = f"{indent}bin_dir = '{cni}/bin'\n"
    elif section.endswith(".cni") and k == "conf_dir":
        line = f"{indent}conf_dir = '{cni}/net.d'\n"
    elif "pinned_images" in section and k == "sandbox":
        line = f"{indent}sandbox = '{pause}'\n"
    elif k == "sandbox_image":
        line = f"{indent}sandbox_image = '{pause}'\n"
    elif runc_options and k == "SystemdCgroup":
        line = f"{indent}SystemdCgroup = false\n"
    elif runc_options and k == "Root":
        line = f"{indent}Root = '{run}/runc'\n"
    elif section.endswith(".registry") and k == "config_path":
        line = f"{indent}config_path = ''\n"
    sys.stdout.write(line)
PATCH_PY_EOF
sudo tee "$STATE_DIR/nodectl" >/dev/null <<'CTL_EOF'
#!/bin/bash
# nodectl start|stop|restart|status : starts and stops the node's containerd, which reads /var/lib/bench62439583/etc/containerd.toml at its start. Must run as root.
LIB=/var/lib/bench62439583
COMMON=$LIB/common
CONFIG=$LIB/etc/containerd.toml
PIDF="$COMMON/run/containerd.pid"
SOCK="$COMMON/run/containerd.sock"
LOG="$COMMON/var/log/containerd.log"

[ "$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }

pid() { [ -s "$PIDF" ] && cat "$PIDF"; }
running() { local p; p=$(pid) && [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "$SOCK" ] && timeout 3 crictl -r "unix://$SOCK" -i "unix://$SOCK" version >/dev/null 2>&1; }

start() {
    if running; then echo "nodectl: containerd is already running (pid $(pid))"; return 0; fi
    mkdir -p "$COMMON/run" "$COMMON/var/lib/containerd" "$COMMON/var/log" "$LIB/cni/bin" "$LIB/cni/net.d"
    setsid -f bash -c 'echo $$ > "$1"; exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin containerd --config "$2"' _ "$PIDF" "$CONFIG" >> "$LOG" 2>&1 < /dev/null
    for _ in $(seq 60); do up && { echo "nodectl: containerd started (pid $(pid))"; return 0; }; sleep 0.5; done
    echo "nodectl: containerd did not answer on $SOCK within 30 s; see $LOG" >&2
    return 1
}

stop() {
    local p
    p=$(pid) || true
    if [ -n "$p" ] && running; then
        kill -TERM "$p" 2>/dev/null
        for _ in $(seq 60); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
        kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    fi
    rm -f "$PIDF" "$SOCK" "$SOCK.ttrpc"
    echo "nodectl: containerd stopped"
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) if running; then echo "containerd is running (pid $(pid))"; else echo "containerd is not running"; exit 1; fi ;;
    *) echo "usage: nodectl start|stop|restart|status" >&2; exit 2 ;;
esac
CTL_EOF
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* myapp: prints "NONCE SALT" (the nonce is its argument, the salt is the file /salt of the image: one build of the image has one salt) and then waits */
int main(int argc, char **argv) {
    char salt[128] = "";
    FILE *f = fopen("/salt", "r");
    if (f) {
        if (!fgets(salt, sizeof salt, f)) salt[0] = 0;
        fclose(f);
    }
    salt[strcspn(salt, "\n")] = 0;
    printf("%s %s\n", argc > 1 ? argv[1] : "-", salt);
    fflush(stdout);
    for (;;) pause();
}
APP_C_EOF
sudo tee "$STATE_DIR/pause.c" >/dev/null <<'PAUSE_C_EOF'
#include <unistd.h>

/* the sandbox ("pause") image of the node: the only file of the image */
int main(void) {
    for (;;) pause();
}
PAUSE_C_EOF

echo "[setup] compiling the two programs (app: prints a nonce and the salt of its image; the sandbox) and building the sandbox image offline..."
sudo gcc -static -Os -s -w -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"
sudo gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"
sudo python3 "$STATE_DIR/jcr.py" tar "$STATE_DIR/pause.tar" "$PAUSE_REF" "$STATE_DIR/pause-bin" pause >/dev/null

echo "[setup] the accounts of the JFrog stand-in (ci and quay-reader, random passwords, readable by root only), the two upstreams with one image each, and the stand-in itself..."
CI_PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
QR_PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
sudo install -d -m 755 "$LIB" "$RUN" "$STORE_DOCKER" "$STORE_QUAY"
printf '{"ci": "%s", "quay-reader": "%s"}\n' "$CI_PW" "$QR_PW" | sudo tee "$LIB/accounts.json" >/dev/null
sudo chmod 600 "$LIB/accounts.json"
sudo python3 "$STATE_DIR/jcr.py" publish "$STORE_DOCKER" "$WEB_REPO" v1 "$STATE_DIR/app-bin" app initial-web >/dev/null
sudo python3 "$STATE_DIR/jcr.py" publish "$STORE_QUAY" "$FLANNEL_REPO" "$FLANNEL_TAG" "$STATE_DIR/app-bin" app initial-flannel >/dev/null
sudo setsid -f python3 "$STATE_DIR/jcr.py" serve "$ADDR_DOCKER" "$ADDR_QUAY" "$ADDR_UP_DOCKER" "$ADDR_UP_QUAY" "$PORT" "$UPORT" "$STORE_DOCKER" "$STORE_QUAY" "$LIB/accounts.json" "$RUN/jcr.log" "$RUN/upstream.log" >/dev/null 2>&1 < /dev/null
for _ in $(seq 20); do curl -s --noproxy '*' --max-time 2 -o /dev/null "http://$ADDR_QUAY:$PORT/v2/" && break; sleep 0.5; done
for a in "$ADDR_DOCKER:$PORT" "$ADDR_QUAY:$PORT" "$ADDR_UP_DOCKER:$UPORT" "$ADDR_UP_QUAY:$UPORT"; do
    curl -s --noproxy '*' --max-time 2 -o /dev/null "http://$a/v2/" || { echo "[setup] ERROR: nothing answers at http://$a/v2/"; exit 1; }
done

echo "[setup] the node: nodectl and containerd's default configuration plus the engineer's registry settings (the ones of the question, with the account ci for both repositories)..."
sudo install -d -m 755 "$BIN" "$ETC" "$COMMON/run" "$LIB/cni/bin" "$LIB/cni/net.d"
sudo install -m 755 "$STATE_DIR/nodectl" "$BIN/nodectl"
containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$COMMON/var/lib/containerd" "$COMMON/run/containerd" "$SOCK" "$LIB/cni" "$PAUSE_REF" | sudo tee "$WORK_DIR/containerd.toml" >/dev/null
sudo grep -q "$PAUSE_REF" "$WORK_DIR/containerd.toml" || { echo "[setup] ERROR: could not set the sandbox image in the configuration"; exit 1; }
sudo grep -qF "$COMMON" "$WORK_DIR/containerd.toml" || { echo "[setup] ERROR: the configuration does not use the node's directories"; exit 1; }
sudo tee -a "$WORK_DIR/containerd.toml" >/dev/null <<TEOF

# registry settings of the node (the question's, for the JFrog repositories at $ADDR_DOCKER:$PORT and $ADDR_QUAY:$PORT): every registry is pulled through the virtual
# repository \`docker\`, the account for the repositories is ci
[plugins.'io.containerd.cri.v1.images'.registry.mirrors.'*']
  endpoint = ['http://$ADDR_DOCKER:$PORT']

[plugins.'io.containerd.cri.v1.images'.registry.mirrors.'docker.io']
  endpoint = ['http://$ADDR_DOCKER:$PORT']

[plugins.'io.containerd.cri.v1.images'.registry.mirrors.'k8s.gcr.io']
  endpoint = ['http://$ADDR_DOCKER:$PORT']

[plugins.'io.containerd.cri.v1.images'.registry.mirrors.'quai.io']
  endpoint = ['http://$ADDR_DOCKER:$PORT']

[plugins.'io.containerd.cri.v1.images'.registry.configs.'$ADDR_DOCKER:$PORT'.auth]
  username = 'ci'
  password = '$CI_PW'

[plugins.'io.containerd.cri.v1.images'.registry.configs.'$ADDR_QUAY:$PORT'.auth]
  username = 'ci'
  password = '$CI_PW'
TEOF
sudo install -m 644 "$WORK_DIR/containerd.toml" "$ETC/containerd.toml"
sudo rm -f "$WORK_DIR/containerd.toml"

echo "[setup] starting the node with nodectl and importing the sandbox image (offline, namespace k8s.io)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$COMMON/var/log/containerd.log" 2>/dev/null; exit 1; }
sudo ctr -a "$SOCK" -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }

echo "[setup] the record of what is true (hashes of the lab's programs and of the accounts, the JFrog stand-in process, the sandbox image)..."
JCR_PID=$(sudo pgrep -f -- "$STATE_DIR/[j]cr.py serve" | head -1)
[ -n "$JCR_PID" ] || { echo "[setup] ERROR: the JFrog stand-in is not running"; exit 1; }
sudo sh -c "cd / && sha256sum '$STATE_DIR/jcr.py' '$BIN/nodectl' '$LIB/accounts.json' > '$STATE_DIR/lab.sha'"
sudo sh -c "echo '$JCR_PID' > '$STATE_DIR/jcr.pid'; awk '{print \$22}' /proc/$JCR_PID/stat > '$STATE_DIR/jcr.start'"
sudo sh -c "crictl -r unix://$SOCK -i unix://$SOCK inspecti -o json '$PAUSE_REF' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"status\"][\"id\"])' > '$STATE_DIR/pause.id'"
sudo test -s "$STATE_DIR/pause.id" || { echo "[setup] ERROR: the sandbox image is not in the node"; exit 1; }

echo "[setup] done. The node (CRI socket $SOCK, configuration $ETC/containerd.toml) pulls through the JFrog stand-in at $ADDR_DOCKER:$PORT; the accounts are in $LIB/accounts.json."
