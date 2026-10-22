#!/bin/bash
set -e

CASE_ID="bench64935442"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files and logs of containerd and k3s, the hub's images and log
LIB_BASE="/var/lib/$CASE_ID"          # roots of containerd, of k3s and its kubelet, the programs, the manifests, the account
CTL_DIR="$LIB_BASE/bin"               # control scripts (not in /run: it is mounted noexec on many hosts)
LIBEXEC="$LIB_BASE/libexec"           # k3s of this machine
CACHE="/var/cache/$CASE_ID"           # the downloaded and checked k3s (kept by cleanup.sh)
CTD_SOCK="$RUN_BASE/containerd.sock"
HUB_DIR="$RUN_BASE/hub"               # the images of the stand-in for the private repository on Docker Hub (blobs, tags.json)
CERTS="$LIB_BASE/certs.d"             # containerd's hosts directory
ADDR="127.64.93.54"                   # the stand-in: registry on port 5000, token service on port 5001
REG_PORT=5000
TOK_PORT=5001
REPO="benchlab64935/blaw-service"     # the private repository, docker.io/$REPO
TAG="v0.3.10"
NODE="bench64935442-node"
PAUSE_REF="bench64935442.local/pause:1"      # sandbox ("pause") image, built here: no download at run time
CNI_CRI="$LIB_BASE/cni-cri"                  # stub plugins for the pod sandboxes of the kubelet
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only): the lab's programs and their hashes

K3S_VERSION="v1.30.5+k3s1"
# release asset and sha256 per architecture (sha256sum-<arch>.txt of the k3s release)
case "$(uname -m)" in
    x86_64)        K3S_ASSET="k3s";       K3S_SHA256="322fbdc904deb1bf2f7a4460c0ae616db3aea75b8aefe911286946cdb0893d95" ;;
    aarch64|arm64) K3S_ASSET="k3s-arm64"; K3S_SHA256="da3b23dc736401259f2e5ada5c481f8302d4f8a55b6d580e1abecaf85e89f2ac" ;;
    *)             K3S_ASSET=""; K3S_SHA256="" ;;
esac
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
OWNED_MARKER="$LIB_BASE/host_dirs_owned"     # k3s' fixed directories are the case's own once this exists

CTR="sudo ctr -a $CTD_SOCK"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking containerd (2.x), ctr, runc, curl, tar, python3 and sudo are installed (the runtime under test)..."
for b in containerd ctr runc curl tar python3 sha256sum sudo; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
[ -n "$K3S_ASSET" ] || { echo "[setup] ERROR: no k3s is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
CTD_VER=$(containerd --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)     # "containerd github.com/containerd/containerd/v2 v2.2.1 ..." or "containerd containerd.io 2.2.1 ..." (Docker's package)
[ "${CTD_VER%%.*}" -ge 2 ] 2>/dev/null || { echo "[setup] ERROR: containerd 2.x is needed (the configuration of the lab is the one of version 3 and 4), found: $(containerd --version)"; exit 1; }
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking this host has no k3s or kubelet state of its own (they keep files in fixed places that this case manages)..."
for d in /etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s; do
    [ ! -e "$d" ] || { echo "[setup] ERROR: $d exists: this host has its own k3s or kubelet state, the case would damage it"; exit 1; }
done
for c in k3s-server k3s-agent kubelet; do
    ! pgrep -x "$c" >/dev/null 2>&1 || { echo "[setup] ERROR: a $c process runs on this host: the case needs a host without k3s or a kubelet"; exit 1; }
done

echo "[setup] making sure gcc is available (two tiny static programs, so nothing has to be pulled from a public registry)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] checking that $ADDR:$REG_PORT and $ADDR:$TOK_PORT are free..."
python3 - "$ADDR" "$REG_PORT" "$TOK_PORT" <<'PYEOF' || { echo "[setup] ERROR: something already listens on $ADDR:$REG_PORT or $ADDR:$TOK_PORT"; exit 1; }
import socket, sys
for port in sys.argv[2:4]:
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)     # sockets in TIME_WAIT of a previous run do not count; a listener does
    try:
        s.bind((sys.argv[1], int(port)))
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
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR" "$LIBEXEC" "$CNI_CRI/bin" "$CNI_CRI/net.d" "$CERTS/docker.io" "$HUB_DIR"
# the network namespaces that are there, and the log directories of the kubelet, which other k3s or kubelet cases may use too: what is there now
# stays, cleanup.sh removes only what the case's kubelet adds
ls /run/netns 2>/dev/null | sudo tee "$LIB_BASE/netns.before" >/dev/null || true
for d in pods containers; do ls -A "/var/log/$d" 2>/dev/null | sudo tee "$LIB_BASE/logs.$d.before" >/dev/null || true; done
sudo touch "$OWNED_MARKER"      # from here on cleanup.sh may remove the fixed directories
cd "$WORK_DIR"

echo "[setup] k3s $K3S_VERSION: from the cache $CACHE, else downloaded; the sha256 is checked either way..."
sudo mkdir -p "$CACHE"
fetch() {   # $1 = cache file, $2 = sha256, $3 = URL, $4 = local copy from the environment (may be empty)
    if sudo test -f "$1" && echo "$2  $1" | sudo sha256sum -c - >/dev/null 2>&1; then return 0; fi
    local tmp="$WORK_DIR/download"
    if [ -n "$4" ]; then cp "$4" "$tmp"
    else curl -fsSL --retry 3 --max-time 600 -o "$tmp" "$3" || { echo "[setup] ERROR: could not download $3"; exit 1; }
    fi
    echo "$2  $tmp" | sha256sum -c - >/dev/null 2>&1 || { rm -f "$tmp"; echo "[setup] ERROR: $3 has the wrong sha256"; exit 1; }
    sudo install -m 644 "$tmp" "$1"
    rm -f "$tmp"
}
fetch "$CACHE/$K3S_ASSET-$K3S_VERSION" "$K3S_SHA256" "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/$K3S_ASSET" "${BENCH64935442_K3S_BIN:-}"
sudo install -m 755 "$CACHE/$K3S_ASSET-$K3S_VERSION" "$LIBEXEC/k3s"
K3S_BIN="$LIBEXEC/k3s"
"$K3S_BIN" --version | head -1

echo "[setup] writing the lab's programs (the stand-in for the private repository on Docker Hub, the containerd configuration patch, two tiny C programs)..."
sudo tee "$STATE_DIR/hub.py" >/dev/null <<'HUB_PY_EOF'
#!/usr/bin/env python3
"""hub.py serve DIR ADDR REGPORT TOKPORT ACCOUNT_JSON LOG    : the lab's stand-in for Docker Hub: a registry (REGPORT) and its token service (TOKPORT) on ADDR
   hub.py publish DIR REPO TAG BINARY ENTRY [SALT]           : put a new image build (one layer with BINARY as /ENTRY and a file /salt) into DIR; prints its digests as JSON
   hub.py tar OUT REF BINARY ENTRY                           : the same image as an OCI archive (for ctr images import)

The rules are those of a private repository: the registry answers 401 with a Bearer challenge; the token service gives a token to a request without credentials (an ANONYMOUS token, which has no access to the
repository) or with the Basic credentials of the account (an ACCOUNT token), and 401 to wrong credentials (it answers 405 to POST: clients fall back to GET). With an anonymous token every request for the
repository (HEAD or GET of a manifest, a blob) is refused with 401 insufficient_scope; with an account token everything is served. One JSON line per request in LOG.
"""
import base64
import gzip
import hashlib
import hmac
import io
import json
import os
import re
import secrets
import sys
import tarfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"
ARCH = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
SERVICE = "registry.hub.lab"


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


def serve(d, addr, regport, tokport, account_json, logfile):
    account = json.load(open(account_json))
    secret = secrets.token_bytes(32)
    lock = threading.Lock()
    log = open(logfile, "a", buffering=1)

    def record(**kw):
        kw["t"] = round(time.time(), 3)
        with lock:
            log.write(json.dumps(kw, sort_keys=True) + "\n")

    def mint(sub):
        body = base64.urlsafe_b64encode(json.dumps({"sub": sub, "exp": time.time() + 300}).encode()).decode()
        return body + "." + hmac.new(secret, body.encode(), hashlib.sha256).hexdigest()

    def who(token):
        try:
            body, sig = token.rsplit(".", 1)
            if not hmac.compare_digest(sig, hmac.new(secret, body.encode(), hashlib.sha256).hexdigest()):
                return None
            c = json.loads(base64.urlsafe_b64decode(body.encode()))
            return c["sub"] if c["exp"] > time.time() else None
        except Exception:                                           # noqa: BLE001
            return None

    class Base(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "hub-lab"

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
            self.status = code

    class Token(Base):
        def do_POST(self):
            self.status = 0
            self.rfile.read(int(self.headers.get("Content-Length") or 0))       # the body must be read, or it is taken for the next request on this connection
            self.send(405, b'{"errors":[{"code":"UNSUPPORTED","message":"POST is not supported"}]}')
            record(srv="token", method="POST", path=self.path, auth="-", who="-", status=405, ua=self.headers.get("User-Agent", ""))

        def do_GET(self):
            h = self.headers.get("Authorization", "")
            kind, who_ = "none", "anonymous"
            if h.lower().startswith("basic "):
                kind = "basic"
                try:
                    user, pw = base64.b64decode(h.split(None, 1)[1]).decode().split(":", 1)
                except Exception:                                   # noqa: BLE001
                    user, pw = "", ""
                who_ = user if (user == account["user"] and hmac.compare_digest(pw, account["password"])) else "rejected"
            elif h:
                kind, who_ = "other", "rejected"
            if who_ == "rejected":
                self.send(401, b'{"details":"incorrect username or password"}')
            else:
                tok = mint(who_)
                self.send(200, json.dumps({"token": tok, "access_token": tok, "expires_in": 300}).encode())
            q = parse_qs(urlparse(self.path).query)
            record(srv="token", method="GET", path=urlparse(self.path).path, scope=",".join(q.get("scope", [])), service=",".join(q.get("service", [])),
                   auth=kind, who=who_, status=self.status, ua=self.headers.get("User-Agent", ""))

    class Registry(Base):
        def challenge(self, scope="", more=""):
            realm = 'Bearer realm="http://%s:%d/token",service="%s"' % (addr, tokport, SERVICE)
            return {"WWW-Authenticate": realm + (',scope="%s"' % scope if scope else "") + ("," + more if more else "")}

        def dispatch(self, head):
            u = urlparse(self.path)
            path, h = u.path, self.headers.get("Authorization", "")
            m = re.match(r"^/v2/(.+)/(manifests|blobs)/([^/]+)$", path)
            scope = "repository:%s:pull" % m.group(1) if m else ""
            sub = who(h.split(None, 1)[1]) if h.lower().startswith("bearer ") and len(h.split(None, 1)) == 2 else None
            auth = "bearer" if h.lower().startswith("bearer ") else ("-" if not h else "other")

            def done(code, body=b"", ctype="application/json", extra=None):
                self.send(code, body, ctype, extra, head)
                record(srv="registry", method=self.command, path=path, auth=auth, who=sub or "-", status=code, ua=self.headers.get("User-Agent", ""))

            if path == "/v2/" or path == "/v2":
                return done(200, b"{}") if sub else done(401, b'{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}', extra=self.challenge())
            if not m:
                return done(404, b'{"errors":[{"code":"NAME_UNKNOWN","message":"not found"}]}')
            if not sub:
                return done(401, b'{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}', extra=self.challenge(scope))
            repo, kind, ref = m.groups()
            if sub == "anonymous":
                return done(401, json.dumps({"errors": [{"code": "UNAUTHORIZED", "message": "authentication required", "detail": [{"Type": "repository", "Name": repo, "Action": "pull"}]}]}).encode(),
                            extra=self.challenge(scope, 'error="insufficient_scope"'))
            digest = ref
            if kind == "manifests" and not ref.startswith("sha256:"):
                try:
                    digest = json.load(open(os.path.join(d, "tags.json")))["%s:%s" % (repo, ref)]
                except (OSError, ValueError, KeyError):
                    return done(404, b'{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}')
            try:
                data = open(os.path.join(d, "blobs", digest.split(":")[1]), "rb").read()
            except (OSError, IndexError):
                return done(404, b'{"errors":[{"code":"BLOB_UNKNOWN","message":"unknown"}]}')
            ctype = json.loads(data).get("mediaType", DOCKER_MANIFEST) if kind == "manifests" else "application/octet-stream"
            extra = {"Docker-Content-Digest": digest}
            rng = re.match(r"bytes=(\d+)-(\d*)$", self.headers.get("Range", ""))
            if rng and kind == "blobs" and not head:
                a = int(rng.group(1))
                b = int(rng.group(2)) if rng.group(2) else len(data) - 1
                extra["Content-Range"] = "bytes %d-%d/%d" % (a, b, len(data))
                return done(206, data[a:b + 1], ctype, extra)
            return done(200, data, ctype, extra)

        def do_GET(self):
            self.dispatch(False)

        def do_HEAD(self):
            self.dispatch(True)

    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer.allow_reuse_address = True
    a, b = ThreadingHTTPServer((addr, regport), Registry), ThreadingHTTPServer((addr, tokport), Token)
    threading.Thread(target=b.serve_forever, daemon=True).start()
    a.serve_forever()


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "serve":
        serve(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6], sys.argv[7])
    elif mode == "publish":
        publish(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7] if len(sys.argv) > 7 else "")
    elif mode == "tar":
        make_tar(*sys.argv[2:6])
HUB_PY_EOF
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'PATCH_PY_EOF'
"""patch_config.py LIB RUN SOCK CNI PAUSE HOSTSDIR < default.toml > template.toml : containerd's default configuration of the installed version (config version 3 of containerd 2.0-2.2 or 4 of 2.3)
turned into the node's STOCK TEMPLATE: root, state, socket, CNI directories and the runc runtime root are the strings given (the lab passes ${SNAP_COMMON}/... and ${SNAP_DATA}/... as
literal text, which the node's launcher replaces at every start), NRI off, a local sandbox image, runc on the cgroupfs driver, and the registry's config_path set to the lab's hosts directory (the rest of the registry settings stay empty)."""
import re
import sys

lib, run, sock, cni, pause, hosts = sys.argv[1:7]
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
        line = f"{indent}config_path = '{hosts}'\n"
    sys.stdout.write(line)
PATCH_PY_EOF
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void bye(int sig) { _exit(0); }

/* the service: prints "SALT <salt>" (the salt is the file /salt of its image: one build of the image has one salt) and then waits */
int main(void) {
    char salt[128] = "";
    FILE *f = fopen("/salt", "r");
    if (f) {
        if (!fgets(salt, sizeof salt, f)) salt[0] = 0;
        fclose(f);
    }
    salt[strcspn(salt, "\n")] = 0;
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    printf("SALT %s\n", salt);
    fflush(stdout);
    for (;;) pause();
}
APP_C_EOF
sudo tee "$STATE_DIR/pause.c" >/dev/null <<'PAUSE_C_EOF'
#include <signal.h>
#include <unistd.h>

static void bye(int sig) { _exit(0); }

/* the sandbox ("pause") image of the node: the only file of the image */
int main(void) {
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    for (;;) pause();
}
PAUSE_C_EOF

echo "[setup] compiling the two programs (app: prints the salt of its image; the sandbox) and building the sandbox image offline..."
sudo gcc -static -Os -s -w -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"
sudo gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"
sudo python3 "$STATE_DIR/hub.py" tar "$STATE_DIR/pause.tar" "$PAUSE_REF" "$STATE_DIR/pause-bin" pause >/dev/null

echo "[setup] the account of the lab (user hubuser, a random password, readable by root only) and the stand-in for the private repository on Docker Hub at $ADDR..."
PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
printf '{"user": "hubuser", "password": "%s"}\n' "$PW" | sudo tee "$LIB_BASE/account.json" >/dev/null
sudo chmod 600 "$LIB_BASE/account.json"
sudo python3 "$STATE_DIR/hub.py" publish "$HUB_DIR" "$REPO" "$TAG" "$STATE_DIR/app-bin" app initial >/dev/null
sudo setsid -f python3 "$STATE_DIR/hub.py" serve "$HUB_DIR" "$ADDR" "$REG_PORT" "$TOK_PORT" "$LIB_BASE/account.json" "$RUN_BASE/hub.log" >/dev/null 2>&1 < /dev/null
for _ in $(seq 20); do curl -s --noproxy '*' --max-time 2 -o /dev/null "http://$ADDR:$REG_PORT/v2/" && break; sleep 0.5; done
curl -s --noproxy '*' --max-time 2 -o /dev/null "http://$ADDR:$REG_PORT/v2/" || { echo "[setup] ERROR: the registry does not answer at http://$ADDR:$REG_PORT/v2/"; exit 1; }

echo "[setup] the node's registry configuration: docker.io is pulled from the stand-in (hosts directory $CERTS), with no credentials in it..."
cat <<CEOF | sudo tee "$CERTS/docker.io/hosts.toml" >/dev/null
# docker.io of this node is served by the lab's stand-in for Docker Hub
server = "http://$ADDR:$REG_PORT"
CEOF

echo "[setup] starting this machine's containerd (own socket, root and state; containerd's default config of the installed version, moved into that"
echo "[setup] root/state, NRI off, stub network plugins for the pod sandboxes of the kubelet, and the sandbox image of the pods)..."
containerd config default \
    | sudo python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" "$CNI_CRI" "$PAUSE_REF" "$CERTS" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
grep -q "$PAUSE_REF" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
grep -q "$CTD_SOCK" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the socket in the containerd config"; exit 1; }
grep -q "$CERTS" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the registry's config_path in the containerd config"; exit 1; }
# Two stub network plugins for the pod sandboxes (containerd's CRI always adds "loopback" in front of the configured one):
# they answer CNI like real plugins but set no interface up. Nothing in this case needs a network.
cat <<'CEOF' | sudo tee "$CNI_CRI/bin/loopback" >/dev/null
#!/bin/bash
cat >/dev/null
case "$CNI_COMMAND" in
    ADD) echo '{"cniVersion":"1.0.0","interfaces":[{"name":"lo","sandbox":"'"$CNI_NETNS"'"}],"ips":[{"address":"127.0.0.1/8","interface":0}]}' ;;
    VERSION) echo '{"cniVersion":"1.0.0","supportedVersions":["0.3.0","0.3.1","0.4.0","1.0.0","1.1.0"]}' ;;
    *) ;;
esac
CEOF
cat <<'CEOF' | sudo tee "$CNI_CRI/bin/benchnet" >/dev/null
#!/bin/bash
cat >/dev/null
case "$CNI_COMMAND" in
    ADD) echo '{"cniVersion":"1.0.0","interfaces":[{"name":"'"$CNI_IFNAME"'","sandbox":"'"$CNI_NETNS"'"}],"ips":[{"address":"10.88.0.2/16","interface":0}]}' ;;
    VERSION) echo '{"cniVersion":"1.0.0","supportedVersions":["0.3.0","0.3.1","0.4.0","1.0.0","1.1.0"]}' ;;
    *) ;;
esac
CEOF
sudo chmod 755 "$CNI_CRI/bin/loopback" "$CNI_CRI/bin/benchnet"
echo '{"cniVersion":"1.0.0","name":"benchnet","plugins":[{"type":"benchnet"}]}' | sudo tee "$CNI_CRI/net.d/10-benchnet.conflist" >/dev/null
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
$CTR -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 \
    || { echo "[setup] ERROR: ctr could not import the sandbox image"; exit 1; }

echo "[setup] writing the Kubernetes (k3s) configuration $K3S_CONFIG, with this containerd as its runtime, and the scripts"
echo "[setup] of this machine: k3sctl and kubectl..."
sudo mkdir -p /etc/rancher/k3s
cat <<CEOF | sudo tee "$K3S_CONFIG" >/dev/null
# configuration of the Kubernetes of this machine
data-dir: $LIB_BASE/k3s
https-listen-port: 16443
node-name: $NODE
container-runtime-endpoint: unix://$CTD_SOCK
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
cat <<CEOF | sudo tee "$CTL_DIR/kubectl" >/dev/null
#!/bin/bash
# the kubectl of this machine's Kubernetes
exec env KUBECONFIG=/etc/rancher/k3s/k3s.yaml K3S_DATA_DIR="$LIB_BASE/k3s" "$K3S_BIN" kubectl "\$@"
CEOF
sudo chmod 755 "$CTL_DIR/k3sctl" "$CTL_DIR/kubectl"

echo "[setup] starting k3s. Waiting for the node $NODE to be Ready..."
sudo "$CTL_DIR/k3sctl" start >/dev/null
KC="sudo $CTL_DIR/kubectl"
READY=""
for _ in $(seq 1 90); do
    READY=$($KC get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ "$READY" = "True" ] && break
    sleep 2
done
if [ "$READY" != "True" ]; then
    echo "[setup] ERROR: the node $NODE did not become Ready; last log lines of k3s:"
    sudo tail -5 "$RUN_BASE/k3s.log" 2>/dev/null | cut -c1-200
    exit 1
fi
echo "  -> node $NODE Ready, container runtime $($KC get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')"
for _ in $(seq 1 60); do
    $KC get serviceaccount default -n default >/dev/null 2>&1 && break
    sleep 1
done
$KC get serviceaccount default -n default >/dev/null 2>&1 || { echo "[setup] ERROR: the service account default did not appear"; exit 1; }

echo "[setup] the Secret regcred (docker-registry, for https://index.docker.io/v1/) and the Deployment blaw, as the engineer wrote them..."
$KC create secret docker-registry regcred -n default --docker-server=https://index.docker.io/v1/ \
    --docker-username=hubuser --docker-password="$PW" --docker-email=engineer@example.com >/dev/null \
    || { echo "[setup] ERROR: could not create the Secret"; exit 1; }
cat <<CEOF | sudo tee "$LIB_BASE/blaw.yaml" >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blaw
  namespace: default
  labels:
    app: blaw
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: blaw
  template:
    metadata:
      labels:
        app: blaw
    spec:
      containers:
      - name: transcribe-service
        image: $REPO:$TAG
CEOF
sudo chmod 644 "$LIB_BASE/blaw.yaml"
$KC apply -f "$LIB_BASE/blaw.yaml" >/dev/null || { echo "[setup] ERROR: could not create the Deployment"; exit 1; }

echo "[setup] waiting for the Pod of blaw to report the pull error..."
WAITING=""
for _ in $(seq 1 90); do
    WAITING=$($KC get pods -n default -l app=blaw -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
    case "$WAITING" in ErrImagePull|ImagePullBackOff) break ;; esac
    sleep 2
done
case "$WAITING" in ErrImagePull|ImagePullBackOff) echo "  -> Pod of blaw: $WAITING" ;;
    *) echo "[setup] ERROR: the Pod of blaw is not failing to pull its image (state: ${WAITING:-none})"; exit 1 ;; esac

echo "[setup] the record of what is true (hashes of the lab's programs, configuration and account, the hub process, the Secret)..."
HUB_PID=$(sudo pgrep -f -- "$STATE_DIR/[h]ub.py serve" | head -1)
[ -n "$HUB_PID" ] || { echo "[setup] ERROR: the hub process is not running"; exit 1; }
sudo sh -c "cd / && sha256sum '$STATE_DIR/hub.py' '$LIB_BASE/account.json' '$CERTS/docker.io/hosts.toml' '$RUN_BASE/config.toml' '$K3S_CONFIG' '$CTL_DIR/containerdctl' '$CTL_DIR/k3sctl' '$CTL_DIR/kubectl' > '$STATE_DIR/lab.sha'"
sudo sh -c "echo '$HUB_PID' > '$STATE_DIR/hub.pid'; awk '{print \$22}' /proc/$HUB_PID/stat > '$STATE_DIR/hub.start'"
echo "[setup] Done."
