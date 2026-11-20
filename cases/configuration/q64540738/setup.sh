#!/bin/bash
set -e

CASE_ID="bench64540738"
RUN_BASE="/run/$CASE_ID"              # pid files and logs of the daemons; the socket directory of containerd
LIB_BASE="/var/lib/$CASE_ID"          # containerd's root and configuration, the registry, the CA, the staged releases, the CNI directories, the control script
CACHE_DIR="/var/cache/$CASE_ID"       # the pinned release downloads (kept by cleanup.sh: they are checked by sha256 and re-used)
CTD_DIR="$RUN_BASE/ctd"               # seen as /run/containerd by the daemons (faasd's provider has that path built in)
CTD_SOCK="$CTD_DIR/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
CNI_DIR="$LIB_BASE/cni"               # seen as /opt/cni/bin, /etc/cni/net.d and /var/lib/cni by the daemons
REG_DIR="$LIB_BASE/registry"          # the registry's blobs, state.json, requests.log and the account file
CERT_DIR="$LIB_BASE/certs"            # the CA of the registry's certificate (the provider trusts it) and the registry's key pair
REL_DIR="$LIB_BASE/releases"          # the faasd release binaries the engineer has downloaded (for this machine's architecture)
REG_ADDR="10.66.54.40"                # an address of its own (a /32 alias of lo): the registry host of the thread
REG_PORT=15064
REG_HOST="$REG_ADDR:$REG_PORT"
REG_USER="benchuser"
ORG="$CASE_ID"                        # the repositories below it need the account (and are the only ones the registry accepts writes for)
REPO="$ORG/fn"
FAASD_BIN="/usr/local/bin/faasd"      # where a faasd installation puts the provider binary
FAASD_DIR="/var/lib/faasd"            # faasd's secrets, hosts, resolv.conf and .docker
PROVIDER_PORT=8081
V_OLD="0.10.0"; V_NEW="0.13.0"

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the tools (the machine's own containerd, runc, CNI and faasd are not touched: this case runs private instances of containerd and faasd's provider)..."
for b in containerd ctr runc containerd-shim-runc-v2 curl python3 sudo ip sha256sum openssl iptables nsenter unshare tar; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking that nothing of faasd is on this machine and that the address, the ports and the CNI network are free..."
[ ! -e "$FAASD_BIN" ] || { echo "[setup] ERROR: $FAASD_BIN exists: this machine already has a faasd installation"; exit 1; }
[ ! -e "$FAASD_DIR" ] || { echo "[setup] ERROR: $FAASD_DIR exists: this machine already has a faasd installation"; exit 1; }
! ip link show openfaas0 >/dev/null 2>&1 || { echo "[setup] ERROR: the bridge openfaas0 exists"; exit 1; }
! ip -4 route show 2>/dev/null | grep -qF "10.62.0.0/16" || { echo "[setup] ERROR: a route for 10.62.0.0/16 (faasd's function network) exists"; exit 1; }
! ip -4 addr show dev lo 2>/dev/null | grep -qF "$REG_ADDR/" || { echo "[setup] ERROR: $REG_ADDR is already an address of this host"; exit 1; }
for port in $REG_PORT $PROVIDER_PORT; do
    ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$port\$" || { echo "[setup] ERROR: something already listens on port $port"; exit 1; }
done
case "$(uname -m)" in
    x86_64)  SFX=""; CNI_ARCH="amd64" ;;
    aarch64) SFX="-arm64"; CNI_ARCH="arm64" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] making sure gcc is available (the function images are static programs, so no image has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] the pinned downloads (faasd $V_OLD and $V_NEW release binaries, CNI plugins v0.8.5; sha256 checked, cached in $CACHE_DIR)..."
sudo mkdir -p "$CACHE_DIR"
fetch() {   # $1 = url, $2 = sha256, $3 = file name in the cache
    local f="$CACHE_DIR/$3"
    if [ -f "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$2" ]; then return 0; fi
    sudo rm -f "$f" "$f.part"
    sudo curl -fsSL --retry 3 --max-time 300 -o "$f.part" "$1" || { echo "[setup] ERROR: could not download $1"; exit 1; }
    [ "$(sha256sum "$f.part" | cut -d' ' -f1)" = "$2" ] || { echo "[setup] ERROR: $1 does not have the expected sha256 $2"; sudo rm -f "$f.part"; exit 1; }
    sudo mv -f "$f.part" "$f"
}
if [ "$CNI_ARCH" = amd64 ]; then
    OLD_SHA=0cc48c642e077b9244ff0ae6147f196fcbc99bd4c22fa68b7260e23c8082af06; NEW_SHA=b830b084dffb00805c7645c99b53b2913dd6cfb5d4c45ff91857edcc2b4b33ab
    CNI_SHA=bd682ffcf701e8f83283cdff7281aad0c83b02a56084d6e601216210732833f9
else
    OLD_SHA=afafdfb84fea1128260d90e243d1616d3377be80a80828ce40e30c9e11d9a7e4; NEW_SHA=8d642ba3c2395d7d6e3c0dac52be8731213ca30433548fbd775fc6e37760eaa2
    CNI_SHA=a7881ec37e592c897bdfd2a225b4ed74caa981e3c4cdcf8f45574f8d2f111bce
fi
fetch "https://github.com/openfaas/faasd/releases/download/$V_OLD/faasd$SFX" "$OLD_SHA" "faasd-$V_OLD"
fetch "https://github.com/openfaas/faasd/releases/download/$V_NEW/faasd$SFX" "$NEW_SHA" "faasd-$V_NEW"
fetch "https://github.com/containernetworking/plugins/releases/download/v0.8.5/cni-plugins-linux-$CNI_ARCH-v0.8.5.tgz" "$CNI_SHA" "cni-plugins.tgz"

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$CTD_DIR" "$LIB_BASE/bin" "$LIB_BASE/etc" "$REG_DIR" "$CERT_DIR" "$REL_DIR" "$CNI_DIR/bin" "$CNI_DIR/net.d" "$CNI_DIR/lib"
cd "$WORK_DIR"

# what this setup changes on the machine outside its own directories, recorded for cleanup.sh: the directories that did not exist (the mount points of the private
# CNI and containerd directories, parents first), the iptables chains and the packet-forwarding switch as they were
CREATED="$LIB_BASE/created"
sudo touch "$CREATED"
mkpt() {   # $1 = directory: create it with the missing parents, recording each one made
    local p="$1" miss=() i
    while [ ! -e "$p" ]; do miss+=("$p"); p=$(dirname "$p"); done
    for ((i = ${#miss[@]} - 1; i >= 0; i--)); do sudo mkdir "${miss[i]}"; echo "dir ${miss[i]}" | sudo tee -a "$CREATED" >/dev/null; done
}
for d in /run/containerd /opt/cni/bin /etc/cni/net.d /var/lib/cni; do mkpt "$d"; done
for c in CNI-FORWARD CNI-ADMIN; do
    if sudo iptables -w -S "$c" >/dev/null 2>&1; then echo "chain $c present" | sudo tee -a "$CREATED" >/dev/null; else echo "chain $c absent" | sudo tee -a "$CREATED" >/dev/null; fi
done
echo "ip_forward $(cat /proc/sys/net/ipv4/ip_forward)" | sudo tee -a "$CREATED" >/dev/null

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of the daemon itself (exec keeps the pid);
# setsid + all three fds redirected so it outlives this script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] the address of the registry: $REG_ADDR/32 on lo..."
sudo ip addr add "$REG_ADDR/32" dev lo

echo "[setup] the function images, built offline in DOCKER format: a static HTTP server on port 8080 (what faasd expects of a function) that answers with a line holding"
echo "[setup] its image's token; two tags, 1.0 and verify..."
cat > "$STATE_DIR/fn.c" <<'CEOF'
#include <arpa/inet.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void bye(int s) { (void)s; _exit(0); }
int main(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, bye);
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(8080); a.sin_addr.s_addr = INADDR_ANY;
    if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 16)) return 1;
    const char *body = "bench64540738-fn-ok token=" TOKEN "\n";
    char resp[512]; int n = snprintf(resp, sizeof resp, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s", strlen(body), body);
    for (;;) { int c = accept(s, 0, 0); if (c < 0) continue; char buf[2048]; (void)read(c, buf, sizeof buf); (void)write(c, resp, n); close(c); }
}
CEOF
cat > "$STATE_DIR/mkimg.py" <<'MKIMGEOF'
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
MKIMGEOF
for k in v1 vv; do
    t="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
    echo "$t" > "$STATE_DIR/token.$k"
    gcc -static -Os -s -w -DTOKEN="\"$t\"" -o "$STATE_DIR/fn.$k" "$STATE_DIR/fn.c"
done
mk() { python3 "$STATE_DIR/mkimg.py" "$1" "$2" "$STATE_DIR/fn.$3" "$STATE_DIR/$3.tar" > "$STATE_DIR/$3.json"; }
mk "$REG_HOST/$REPO:1.0"    "$(cat "$STATE_DIR/token.v1")" v1
mk "$REG_HOST/$REPO:verify" "$(cat "$STATE_DIR/token.vv")" vv

echo "[setup] the certificate authority of the lab and the registry's certificate (for the address $REG_ADDR)..."
sudo bash -c "cd '$CERT_DIR' && umask 077 && cat > ext.cnf <<'EXTEOF'
subjectAltName=IP:@ADDR@
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EXTEOF
sed -i 's/@ADDR@/$REG_ADDR/' ext.cnf
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 30 -subj '/CN=bench64540738 lab CA' \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj '/CN=$REG_ADDR' >/dev/null 2>&1
openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 30 -extfile ext.cnf >/dev/null 2>&1
rm -f srv.csr ca.srl ca.key
chmod 644 ca.pem srv.pem; chmod 600 srv.key"
[ -s "$CERT_DIR/srv.pem" ] || { echo "[setup] ERROR: could not make the certificates"; exit 1; }

echo "[setup] the registry (HTTPS on $REG_HOST; token authentication: /v2/ and the repositories below $ORG/ need a Bearer token; its challenge names the token service"
echo "[setup] and the service but NO scope; the token service wants the account $REG_USER (Basic) and a scope for the repository; every request is logged with its"
echo "[setup] authentication), then the two images pushed with the account..."
REG_PASS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
printf '%s:%s\n' "$REG_USER" "$REG_PASS" | sudo tee "$REG_DIR/account" >/dev/null
sudo chmod 600 "$REG_DIR/account"
cat > "$STATE_DIR/registry.py" <<'REGPYEOF'
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
ACCOUNT_FILE, PRIVATE, BIND, CERT, KEY = sys.argv[5:10]
AUTH_USER, AUTH_PASS = open(ACCOUNT_FILE).read().strip().split(":", 1)      # "user:password", a root-only file
AUTH_HEADER = "Basic " + base64.b64encode((AUTH_USER + ":" + AUTH_PASS).encode()).decode()
TOKENS = {}     # bearer token -> repository it was issued for (the token service gives one only for a repository pull scope and the account)
SERVICE = "bench-registry"
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
        host = self.headers.get("Host", "")
        if path == "/token" and m == "POST":     # the OAuth2 flavour of the token service is not offered: clients fall back to the GET flavour
            self._body()
            self._note = " auth=oauth-post"
            return self._reply(405, json.dumps({"errors": [{"code": "UNSUPPORTED", "message": "use GET"}]}).encode(), headers={"Allow": "GET"}, head=head)
        if path == "/token":
            # the token service: Basic account + a scope of the form repository:<name>:<actions> (the Docker token authentication protocol)
            scope = params.get("scope", "")
            self._note = " auth=" + ("basic-ok" if got == AUTH_HEADER else ("basic-bad" if got else "none")) + " scope=" + (scope or "-")
            ms = re.match(r"^repository:([^:]+):((?:pull|push)(?:,(?:pull|push))*)$", scope)
            if got != AUTH_HEADER:
                return self._reply(401, json.dumps({"errors": [{"code": "UNAUTHORIZED", "message": "authentication required"}]}).encode(),
                                   headers={"WWW-Authenticate": 'Basic realm="bench token service"'}, head=head)
            if not ms or params.get("service") != SERVICE or not ms.group(1).startswith(PRIVATE + "/"):
                return self._reply(400, json.dumps({"errors": [{"code": "UNAUTHORIZED", "message": "a scope repository:<name>:pull and the service are required"}]}).encode(), head=head)
            tok = uuid.uuid4().hex
            TOKENS[tok] = ms.group(1)
            return self._reply(200, json.dumps({"token": tok, "access_token": tok, "expires_in": 300}).encode(), head=head)
        if path in ("/v2/", "/v2") or path.startswith("/v2/" + PRIVATE + "/"):
            mrepo = re.match(r"^/v2/(.+?)/(manifests|blobs|tags)/", path)
            repo = mrepo.group(1) if mrepo else None
            if got == AUTH_HEADER:
                state = "basic-ok"      # the account itself (the setup pushes with it)
            elif got.startswith("Bearer ") and repo and TOKENS.get(got[7:]) == repo:
                state = "bearer-ok"
            else:
                state = "bearer-bad" if got else "none"
            self._note = " auth=" + state
            if state not in ("basic-ok", "bearer-ok"):
                self._body()
                # the challenge of this registry carries NO scope: realm and service only
                return self._reply(401, json.dumps({"errors": [{"code": "UNAUTHORIZED", "message": "authentication required"}]}).encode(),
                                   headers={"WWW-Authenticate": 'Bearer realm="https://%s/token",service="%s"' % (host, SERVICE)}, head=head)
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
srv = S((BIND, port), H)
import ssl
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
REGPYEOF
sudo install -m 0644 "$STATE_DIR/registry.py" "$REG_DIR/registry.py"
start_daemon "$RUN_BASE/registry.pid" "$RUN_BASE/registry.out" python3 "$REG_DIR/registry.py" "$REG_DIR" "$REG_PORT" "$REG_DIR/requests.log" "$ORG" "$REG_DIR/account" "$ORG" "$REG_ADDR" "$CERT_DIR/srv.pem" "$CERT_DIR/srv.key"
for _ in $(seq 1 40); do curl -s --max-time 2 --cacert "$CERT_DIR/ca.pem" -o /dev/null "https://$REG_HOST/v2/" && break; sleep 0.25; done
curl -s --max-time 2 --cacert "$CERT_DIR/ca.pem" -o /dev/null "https://$REG_HOST/v2/" || { echo "[setup] ERROR: the registry did not come up"; sudo tail -5 "$RUN_BASE/registry.out"; exit 1; }
cat > "$STATE_DIR/push.py" <<'PUSHEOF'
import base64, http.client, json, ssl, sys, tarfile
tarp, meta, host, port, repo, tag, user, pw, ca = sys.argv[1:10]
m = json.load(open(meta)); t = tarfile.open(tarp)
H = {"Authorization": "Basic " + base64.b64encode((user + ":" + pw).encode()).decode()}
ctx = ssl.create_default_context(cafile=ca)
def blob(d): return t.extractfile("blobs/sha256/" + d.split(":")[1]).read()
def req(method, path, body=None, hdr=None):
    c = http.client.HTTPSConnection(host, int(port), context=ctx); c.request(method, path, body=body, headers=dict(H, **(hdr or {}))); r = c.getresponse(); r.read(); return r.status
for d in (m["config"], m["layer"]):
    s = req("POST", "/v2/%s/blobs/uploads/?digest=%s" % (repo, d), blob(d), {"Content-Type": "application/octet-stream"})
    assert s in (201, 202), "blob upload: HTTP %d" % s
s = req("PUT", "/v2/%s/manifests/%s" % (repo, tag), blob(m["manifest"]), {"Content-Type": m["media_type"]})
assert s == 201, "manifest put: HTTP %d" % s
PUSHEOF
for spec in "v1 1.0" "vv verify"; do
    set -- $spec
    sudo python3 "$STATE_DIR/push.py" "$STATE_DIR/$1.tar" "$STATE_DIR/$1.json" "$REG_ADDR" "$REG_PORT" "$REPO" "$2" "$REG_USER" "$REG_PASS" "$CERT_DIR/ca.pem" || { echo "[setup] ERROR: could not push $REPO:$2"; exit 1; }
done
echo "  -> anonymous /v2/$REPO/manifests/1.0: $(curl -s -o /dev/null -w '%{http_code}' --cacert "$CERT_DIR/ca.pem" "https://$REG_HOST/v2/$REPO/manifests/1.0") (the images are in)"

echo "[setup] faasd as the engineer installed it: the CNI plugins (v0.8.5), containerd's configuration, the provider $V_OLD as $FAASD_BIN, the secrets of the provider API"
echo "[setup] (user admin) in $FAASD_DIR/secrets, and $V_NEW staged in $REL_DIR (the release the engineer downloaded later)..."
sudo tar -xzf "$CACHE_DIR/cni-plugins.tgz" -C "$CNI_DIR/bin"
sudo chmod -R a+rX "$CNI_DIR"
sudo install -m 0755 "$CACHE_DIR/faasd-$V_OLD" "$FAASD_BIN"
sudo install -m 0755 "$CACHE_DIR/faasd-$V_NEW" "$REL_DIR/faasd-$V_NEW"
sudo mkdir -p "$FAASD_DIR/secrets"
echo "admin" | sudo tee "$FAASD_DIR/secrets/basic-auth-user" >/dev/null
ADMIN_PASS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
printf '%s' "$ADMIN_PASS" | sudo tee "$FAASD_DIR/secrets/basic-auth-password" >/dev/null
sudo chmod 640 "$FAASD_DIR/secrets/basic-auth-user" "$FAASD_DIR/secrets/basic-auth-password"
sudo touch "$FAASD_DIR/.$CASE_ID"
sudo tee "$CTD_CONF" >/dev/null <<EOF
version = 3
root = "$LIB_BASE/containerd"
state = "$RUN_BASE/state"
[grpc]
  address = "/run/containerd/containerd.sock"
[plugins."io.containerd.nri.v1.nri"]
  disable = true
EOF
sudo chmod 600 "$CTD_CONF"
cat > "$STATE_DIR/faasdctl" <<'CTLEOF'
#!/bin/bash
# faasdctl start|stop|restart|status [containerd|provider]    (run it with sudo; without a daemon name it means both)
#
# This machine's faasd is two daemons: containerd (the runtime that holds the functions) and `/usr/local/bin/faasd provider` (faasd's own provider: the
# API that deploys, lists and calls the functions, port 8081). They are started and stopped here the way the two systemd units of a faasd installation
# are, and they read their environment and files only when they start.
#
# Both run in a mount namespace of their own, in which four directories are this exercise's own so that the machine's own containerd, CNI plugins and CNI
# configuration are not touched: /run/containerd (the containerd socket), /opt/cni/bin, /etc/cni/net.d and /var/lib/cni. Everything else (/usr/local/bin/faasd,
# /var/lib/faasd with its secrets and .docker, the network) is the machine's own. The provider trusts the registry's certificate authority (SSL_CERT_FILE).
RUN_BASE=@RUN_BASE@
CTD_DIR=@CTD_DIR@
CTD_SOCK=@CTD_SOCK@
CTD_CONF=@CTD_CONF@
CNI=@CNI_DIR@
CA=@CERT_DIR@/ca.pem
FAASD=/usr/local/bin/faasd
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

alive() {   # $1 = name of the pid file, $2 = the process name it must have
    local p
    [ -s "$RUN_BASE/$1.pid" ] && p=$(cat "$RUN_BASE/$1.pid") && [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "$2" ]
}
holder_start() {
    alive holder sleep && return 0
    rm -f "$RUN_BASE/holder.ready"
    setsid -f bash -c 'echo $$ > "$1"; exec unshare -m --propagation private bash -c "$2"' _ "$RUN_BASE/holder.pid" \
        "mount --bind $CTD_DIR /run/containerd && mount --bind $CNI/bin /opt/cni/bin && mount --bind $CNI/net.d /etc/cni/net.d && mount --bind $CNI/lib /var/lib/cni && touch $RUN_BASE/holder.ready && exec sleep infinity" \
        </dev/null >"$RUN_BASE/holder.log" 2>&1
    for _ in $(seq 1 40); do [ -e "$RUN_BASE/holder.ready" ] && return 0; sleep 0.25; done
    echo "the mount namespace of the daemons did not come up"; cat "$RUN_BASE/holder.log" 2>/dev/null; return 1
}
launch() {   # $1 = name (pid file and log), rest = the command, run inside the mount namespace
    local name=$1; shift
    setsid -f bash -c 'echo $$ > "$1"; log="$2"; h="$3"; shift 3; exec nsenter -m -t "$h" -- "$@" >>"$log" 2>&1 </dev/null' \
        _ "$RUN_BASE/$name.pid" "$RUN_BASE/$name.log" "$(cat "$RUN_BASE/holder.pid")" "$@" </dev/null >/dev/null 2>&1
}
stop_one() {   # $1 = name, $2 = process name
    alive "$1" "$2" || { echo "$1 is not running"; return 0; }
    local p; p=$(cat "$RUN_BASE/$1.pid"); kill -TERM "$p"
    for _ in $(seq 1 60); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$p" 2>/dev/null && kill -KILL "$p"
    echo "$1 stopped"
}
start_containerd() {
    alive containerd containerd && { echo "containerd is already running"; return 0; }
    holder_start || return 1
    launch containerd containerd --config "$CTD_CONF"
    for _ in $(seq 1 60); do ctr -a "$CTD_SOCK" version >/dev/null 2>&1 && break; sleep 0.5; done
    ctr -a "$CTD_SOCK" version >/dev/null 2>&1 && echo "containerd started" || { echo "containerd did not come up"; tail -5 "$RUN_BASE/containerd.log"; return 1; }
}
start_provider() {
    alive provider faasd && { echo "provider is already running"; return 0; }
    alive containerd containerd || { echo "containerd is not running: start it first"; return 1; }
    launch provider env basic_auth=true secret_mount_path=/var/lib/faasd/secrets SSL_CERT_FILE="$CA" "$FAASD" provider
    local pw; pw=$(cat /var/lib/faasd/secrets/basic-auth-password)
    for _ in $(seq 1 60); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -u "admin:$pw" http://127.0.0.1:8081/system/functions)" = 200 ] && { echo "provider started"; return 0; }
        sleep 0.5
    done
    echo "provider did not come up"; tail -5 "$RUN_BASE/provider.log"; return 1
}
status_one() {   # $1 = name, $2 = process name
    if alive "$1" "$2"; then echo "$1: active (pid $(cat "$RUN_BASE/$1.pid"))"; else echo "$1: inactive"; return 3; fi
}

what=${2:-all}
case "$what" in all|containerd|provider) ;; *) echo "usage: faasdctl start|stop|restart|status [containerd|provider]"; exit 2 ;; esac
do_start() { [ "$what" != provider ] && { start_containerd || return 1; }; [ "$what" != containerd ] && { start_provider || return 1; }; return 0; }
do_stop() { [ "$what" != containerd ] && stop_one provider faasd; [ "$what" != provider ] && stop_one containerd containerd; return 0; }
case "$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) rc=0; [ "$what" != provider ] && { status_one containerd containerd || rc=3; }; [ "$what" != containerd ] && { status_one provider faasd || rc=3; }; exit $rc ;;
    *) echo "usage: faasdctl start|stop|restart|status [containerd|provider]"; exit 2 ;;
esac
CTLEOF
sed -i -e "s|@RUN_BASE@|$RUN_BASE|g" -e "s|@CTD_DIR@|$CTD_DIR|g" -e "s|@CTD_SOCK@|$CTD_SOCK|g" -e "s|@CTD_CONF@|$CTD_CONF|g" \
    -e "s|@CNI_DIR@|$CNI_DIR|g" -e "s|@CERT_DIR@|$CERT_DIR|g" "$STATE_DIR/faasdctl"
sudo install -m 0755 "$STATE_DIR/faasdctl" "$LIB_BASE/bin/faasdctl"
sudo "$LIB_BASE/bin/faasdctl" start >/dev/null || { echo "[setup] ERROR: faasd did not come up"; sudo tail -15 "$RUN_BASE/containerd.log" "$RUN_BASE/provider.log" 2>/dev/null | cut -c1-250; exit 1; }
echo "  -> containerd $(sudo ctr -a "$CTD_SOCK" version | awk '/Server/ {f=1} f && /Version/ {print $2; exit}') on $CTD_SOCK and the faasd provider $($FAASD_BIN version 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'version: [0-9.]*') on port $PROVIDER_PORT are up"

echo "[setup] the job's wrappers: ctr (against this containerd, namespace openfaas-fn), faas-deploy and fn-call (what faas-cli sends to the provider, and a call of a function)..."
cat > "$WORK_DIR/bin/ctr" <<EOF
#!/bin/sh
# ctr ARGS...: ctr against this machine's containerd (it calls sudo itself); the functions live in the containerd namespace openfaas-fn
exec sudo $(command -v ctr) -a $CTD_SOCK -n openfaas-fn "\$@"
EOF
cat > "$WORK_DIR/bin/faas-deploy" <<'EOF'
#!/bin/sh
# faas-deploy NAME IMAGE [USER:PASSWORD]: deploys a function through the provider's API, the way faas-cli does (POST /system/functions on port 8081, the admin account of
# /var/lib/faasd/secrets); the optional USER:PASSWORD goes into the body as "registryAuth" (base64), as faas-cli sends the registry login it finds in its own docker config.
# It prints the body of the answer and the HTTP status.
[ $# -ge 2 ] || { echo "usage: faas-deploy NAME IMAGE [USER:PASSWORD]"; exit 2; }
PW=$(sudo cat /var/lib/faasd/secrets/basic-auth-password)
if [ -n "$3" ]; then AUTH=$(printf '%s' "$3" | base64 -w0); BODY="{\"service\":\"$1\",\"image\":\"$2\",\"registryAuth\":\"$AUTH\"}"; else BODY="{\"service\":\"$1\",\"image\":\"$2\"}"; fi
curl -s -m 120 -w '\nHTTP %{http_code}\n' -u "admin:$PW" -H 'Content-Type: application/json' -d "$BODY" http://127.0.0.1:8081/system/functions
EOF
cat > "$WORK_DIR/bin/fn-call" <<'EOF'
#!/bin/sh
# fn-call NAME: calls the function NAME through the provider (GET /function/NAME) and prints its answer
[ $# -eq 1 ] || { echo "usage: fn-call NAME"; exit 2; }
PW=$(sudo cat /var/lib/faasd/secrets/basic-auth-password)
curl -s -m 20 -u "admin:$PW" http://127.0.0.1:8081/function/"$1"
EOF
chmod 755 "$WORK_DIR/bin/ctr" "$WORK_DIR/bin/faas-deploy" "$WORK_DIR/bin/fn-call"

echo "[setup] recording the state (root-only): the daemons (pid + start time + program), hashes, the images' digests and tokens, the accounts..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" REG_DIR="$REG_DIR" REG_ADDR="$REG_ADDR" REG_PORT="$REG_PORT" REL_DIR="$REL_DIR" CERT_DIR="$CERT_DIR" \
    REG_USER="$REG_USER" REG_PASS="$REG_PASS" ADMIN_PASS="$ADMIN_PASS" REPO="$REPO" CTD_CONF="$CTD_CONF" CTD_SOCK="$CTD_SOCK" FAASD_BIN="$FAASD_BIN" FAASD_DIR="$FAASD_DIR" \
    V_OLD="$V_OLD" V_NEW="$V_NEW" OLD_SHA="$OLD_SHA" NEW_SHA="$NEW_SHA" python3 - <<'STEOF'
import hashlib, json, os
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def ident(name):
    pid = int(open("%s/%s.pid" % (E["RUN_BASE"], name)).read())
    s = open("/proc/%d/stat" % pid).read()
    return [pid, int(s[s.rindex(")") + 2:].split()[19]), os.readlink("/proc/%d/exe" % pid), os.readlink("/proc/%d/ns/mnt" % pid)]
files = [E["REG_DIR"] + "/registry.py", E["REG_DIR"] + "/account", E["CERT_DIR"] + "/ca.pem", E["CERT_DIR"] + "/srv.pem", E["CTD_CONF"],
         E["LIB_BASE"] + "/bin/faasdctl", E["REL_DIR"] + "/faasd-" + E["V_NEW"], E["FAASD_DIR"] + "/secrets/basic-auth-user", E["FAASD_DIR"] + "/secrets/basic-auth-password",
         E["WORK_DIR"] + "/bin/ctr", E["WORK_DIR"] + "/bin/faas-deploy", E["WORK_DIR"] + "/bin/fn-call"]
imgs = {}
for k, tag in {"v1": "1.0", "vv": "verify"}.items():
    m = json.load(open("%s/%s.json" % (E["STATE_DIR"], k)))
    imgs[tag] = {"repo": E["REPO"], "tag": tag, "token": open("%s/token.%s" % (E["STATE_DIR"], k)).read().strip(),
                 "manifest": m["manifest"], "config": m["config"], "layer": m["layer"]}
d = {"daemons": {n: ident(n) for n in ("registry", "containerd", "provider", "holder")}, "files": {f: sha(f) for f in files},
     "registry_state": sha(E["REG_DIR"] + "/state.json"), "registry_lines": sum(1 for _ in open(E["REG_DIR"] + "/requests.log")),
     "addr": E["REG_ADDR"], "port": int(E["REG_PORT"]), "user": E["REG_USER"], "password": E["REG_PASS"], "admin_password": E["ADMIN_PASS"],
     "repo": E["REPO"], "images": imgs, "ctd_conf": E["CTD_CONF"], "ctd_sock": E["CTD_SOCK"], "faasd_bin": E["FAASD_BIN"], "faasd_dir": E["FAASD_DIR"],
     "old_sha": E["OLD_SHA"], "new_sha": E["NEW_SHA"], "v_old": E["V_OLD"], "v_new": E["V_NEW"]}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
STEOF

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR"/fn.* "$STATE_DIR"/token.* "$STATE_DIR"/v1.* "$STATE_DIR"/vv.* "$STATE_DIR"/mkimg.py "$STATE_DIR"/push.py "$STATE_DIR"/registry.py "$STATE_DIR"/faasdctl
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. The registry at $REG_HOST needs the account for $ORG/*; faasd's provider $V_OLD runs from $FAASD_BIN."
