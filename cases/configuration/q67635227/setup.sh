#!/bin/bash
set -e

CASE_ID="bench67635227"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"
SNAP_DATA="$LIB/current"                         # the node's data directory (MicroK8s: /var/snap/microk8s/current)
SNAP_COMMON="$LIB/common"                        # containerd's root, state, socket and log (MicroK8s: /var/snap/microk8s/common)
ARGS="$SNAP_DATA/args"                           # the template and the generated containerd.toml
BIN="$LIB/bin"                                   # the launcher and mk8sctl (root-owned; not in /run: it is mounted noexec on many hosts)
SOCK="$SNAP_COMMON/run/containerd.sock"
RUN="/run/$CASE_ID"
HUB_DIR="$RUN/hub"                               # the images of the stand-in for Docker Hub (blobs, tags.json) and its log
ADDR="127.67.63.52"                              # the stand-in for Docker Hub: registry on port 5000, token service on port 5001 (another address of lo: no setup of the host)
REG_PORT=5000
TOK_PORT=5001
REPO="benchlab67635/app"                         # the private repository of the account, as docker.io/$REPO
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

echo "[setup] writing the lab's programs (the stand-in for Docker Hub, the node's launcher and control script, the configuration generator, two tiny programs)..."
sudo tee "$STATE_DIR/hub.py" >/dev/null <<'HUB_PY_EOF'
#!/usr/bin/env python3
"""hub.py serve DIR ADDR REGPORT TOKPORT ACCOUNT_JSON LOG    : the lab's stand-in for Docker Hub: a registry (REGPORT) and its token service (TOKPORT) on ADDR
   hub.py publish DIR REPO TAG BINARY ENTRY [SALT]           : put a new image build (one layer with BINARY as /ENTRY and a file /salt) into DIR; prints its digests as JSON
   hub.py tar OUT REF BINARY ENTRY                           : the same image as an OCI archive (for ctr images import)

The rules are those of Docker Hub for anonymous and authenticated pulls: the registry answers 401 with a Bearer challenge; the token service gives a token to a request without credentials
(an ANONYMOUS token) or with the Basic credentials of the account (an ACCOUNT token), and 401 to wrong credentials (it answers 405 to POST: clients fall back to GET). With an anonymous token a HEAD of a
manifest works (Docker Hub does not count it) but a GET of a manifest or a blob gets 429 toomanyrequests, the rate limit of anonymous pulls; with an account token everything is served. One JSON line per request in LOG."""
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
MSG429 = "You have reached your pull rate limit. You may increase the limit by authenticating and upgrading: https://www.docker.com/increase-rate-limit"


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
        def challenge(self, scope=""):
            realm = 'Bearer realm="http://%s:%d/token",service="%s"' % (addr, tokport, SERVICE)
            return {"WWW-Authenticate": realm + (',scope="%s"' % scope if scope else "")}

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
            if sub == "anonymous" and not (head and kind == "manifests"):
                return done(429, json.dumps({"errors": [{"code": "TOOMANYREQUESTS", "message": MSG429}]}).encode(), extra={"Retry-After": "3600"})
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
sudo tee "$STATE_DIR/mk8s-run-containerd" >/dev/null <<'LAUNCHER_EOF'
#!/bin/bash
# The node's containerd launcher, written the way the MicroK8s snap does it (run-containerd-with-args): the file args/containerd.toml is NOT kept, it is made again from
# args/containerd-template.toml every time containerd starts, with ${SNAP_DATA} and ${SNAP_COMMON} replaced by the node's directories; then containerd is exec'd with it.
set -eu
SNAP_DATA=/var/lib/bench67635227/current
SNAP_COMMON=/var/lib/bench67635227/common
ARGS="$SNAP_DATA/args"

mkdir -p "$SNAP_COMMON/run" "$SNAP_COMMON/var/lib/containerd" "$SNAP_COMMON/var/log" "$SNAP_DATA/cni/bin" "$SNAP_DATA/cni/net.d"
tmp=$(mktemp "$ARGS/.containerd.toml.XXXXXX")
sed -e "s@\${SNAP_DATA}@$SNAP_DATA@g" -e "s@\${SNAP_COMMON}@$SNAP_COMMON@g" "$ARGS/containerd-template.toml" > "$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$ARGS/containerd.toml"

echo $$ > "$SNAP_COMMON/run/containerd.pid"
exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin containerd --config "$ARGS/containerd.toml"
LAUNCHER_EOF
sudo tee "$STATE_DIR/mk8sctl" >/dev/null <<'CTL_EOF'
#!/bin/bash
# mk8sctl start|stop|restart|status : starts and stops the node's containerd (like `microk8s start` and `microk8s stop` do for the services of the snap). Must run as root.
SNAP_COMMON=/var/lib/bench67635227/common
BIN=/var/lib/bench67635227/bin
PIDF="$SNAP_COMMON/run/containerd.pid"
SOCK="$SNAP_COMMON/run/containerd.sock"
LOG="$SNAP_COMMON/var/log/containerd.log"

[ "$(id -u)" = 0 ] || { echo "mk8sctl: must run as root (use sudo)" >&2; exit 1; }

pid() { [ -s "$PIDF" ] && cat "$PIDF"; }
running() { local p; p=$(pid) && [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "$SOCK" ] && timeout 3 crictl -r "unix://$SOCK" -i "unix://$SOCK" version >/dev/null 2>&1; }

start() {
    if running; then echo "mk8sctl: containerd is already running (pid $(pid))"; return 0; fi
    mkdir -p "$(dirname "$LOG")" "$SNAP_COMMON/run"
    setsid -f "$BIN/mk8s-run-containerd" >> "$LOG" 2>&1 < /dev/null
    for _ in $(seq 60); do up && { echo "mk8sctl: containerd started (pid $(pid))"; return 0; }; sleep 0.5; done
    echo "mk8sctl: containerd did not answer on $SOCK within 30 s; see $LOG" >&2
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
    echo "mk8sctl: containerd stopped"
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) if running; then echo "containerd is running (pid $(pid))"; else echo "containerd is not running"; exit 1; fi ;;
    *) echo "usage: mk8sctl start|stop|restart|status" >&2; exit 2 ;;
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
sudo python3 "$STATE_DIR/hub.py" tar "$STATE_DIR/pause.tar" "$PAUSE_REF" "$STATE_DIR/pause-bin" pause >/dev/null

echo "[setup] the account of the lab (user hubuser, a random password, readable by root only) and the stand-in for Docker Hub at $ADDR..."
PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
sudo install -d -m 755 "$LIB" "$RUN" "$HUB_DIR"
printf '{"user": "hubuser", "password": "%s"}\n' "$PW" | sudo tee "$LIB/account.json" >/dev/null
sudo chmod 600 "$LIB/account.json"
sudo python3 "$STATE_DIR/hub.py" publish "$HUB_DIR" "$REPO" v1 "$STATE_DIR/app-bin" app initial >/dev/null
sudo setsid -f python3 "$STATE_DIR/hub.py" serve "$HUB_DIR" "$ADDR" "$REG_PORT" "$TOK_PORT" "$LIB/account.json" "$RUN/hub.log" >/dev/null 2>&1 < /dev/null
for _ in $(seq 20); do curl -s --noproxy '*' --max-time 2 -o /dev/null "http://$ADDR:$REG_PORT/v2/" && break; sleep 0.5; done
curl -s --noproxy '*' --max-time 2 -o /dev/null "http://$ADDR:$REG_PORT/v2/" || { echo "[setup] ERROR: the registry does not answer at http://$ADDR:$REG_PORT/v2/"; exit 1; }

echo "[setup] the node: the launcher (makes containerd.toml from the template at every start), mk8sctl, and the template: containerd's default configuration plus the engineer's registry settings..."
sudo install -d -m 755 "$BIN" "$ARGS" "$SNAP_COMMON/run"
sudo install -m 755 "$STATE_DIR/mk8s-run-containerd" "$BIN/mk8s-run-containerd"
sudo install -m 755 "$STATE_DIR/mk8sctl" "$BIN/mk8sctl"
containerd config default | sudo python3 "$STATE_DIR/patch_config.py" '${SNAP_COMMON}/var/lib/containerd' '${SNAP_COMMON}/run/containerd' '${SNAP_COMMON}/run/containerd.sock' '${SNAP_DATA}/cni' "$PAUSE_REF" | sudo tee "$WORK_DIR/containerd-template.toml" >/dev/null
sudo grep -q "$PAUSE_REF" "$WORK_DIR/containerd-template.toml" || { echo "[setup] ERROR: could not set the sandbox image in the configuration"; exit 1; }
sudo grep -qF '${SNAP_COMMON}' "$WORK_DIR/containerd-template.toml" || { echo "[setup] ERROR: the template has no \${SNAP_COMMON}"; exit 1; }
sudo tee -a "$WORK_DIR/containerd-template.toml" >/dev/null <<TEOF

# registry settings of the node: docker.io is pulled from the registry below (the stand-in for Docker Hub), with the authentication block that the documentation shows
[plugins.'io.containerd.cri.v1.images'.registry.mirrors.'docker.io']
  endpoint = ['http://$ADDR:$REG_PORT']

[plugins.'io.containerd.cri.v1.images'.registry.configs.'docker.io'.auth]
  username = ''
  password = ''
  auth = ''
  email = ''
TEOF
sudo install -m 644 "$WORK_DIR/containerd-template.toml" "$ARGS/containerd-template.toml"
sudo rm -f "$WORK_DIR/containerd-template.toml"

echo "[setup] starting the node with mk8sctl and importing the sandbox image (offline, namespace k8s.io)..."
sudo "$BIN/mk8sctl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$SNAP_COMMON/var/log/containerd.log" 2>/dev/null; exit 1; }
sudo ctr -a "$SOCK" -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image"; exit 1; }

echo "[setup] the record of what is true (hashes of the lab's programs and of the account, the hub process, the sandbox image)..."
HUB_PID=$(sudo pgrep -f -- "$STATE_DIR/[h]ub.py serve" | head -1)
[ -n "$HUB_PID" ] || { echo "[setup] ERROR: the hub process is not running"; exit 1; }
sudo sh -c "cd / && sha256sum '$STATE_DIR/hub.py' '$BIN/mk8s-run-containerd' '$BIN/mk8sctl' '$LIB/account.json' > '$STATE_DIR/lab.sha'"
sudo sh -c "echo '$HUB_PID' > '$STATE_DIR/hub.pid'; awk '{print \$22}' /proc/$HUB_PID/stat > '$STATE_DIR/hub.start'"
sudo sh -c "crictl -r unix://$SOCK -i unix://$SOCK inspecti -o json '$PAUSE_REF' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"status\"][\"id\"])' > '$STATE_DIR/pause.id'"
sudo test -s "$STATE_DIR/pause.id" || { echo "[setup] ERROR: the sandbox image is not in the node"; exit 1; }

echo "[setup] done. The node (CRI socket $SOCK, $ARGS/containerd.toml) pulls docker.io/$REPO from $ADDR:$REG_PORT without an account and is refused (429); the account is in $LIB/account.json."
