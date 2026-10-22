#!/bin/bash
set -e

CASE_ID="bench76136482"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="/run/$CASE_ID"                   # containerd's socket, state, pid file and log; the log of the registry and of the token service
LIB="/var/lib/$CASE_ID"               # bin (control scripts), libexec (containerd, ctr, registry), etc (containerd's configuration and its hosts directory), auth (token service), registry, root (containerd's root)
CACHE="/var/cache/$CASE_ID"           # the downloaded and checked containerd and registry releases (kept by cleanup.sh)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ADDR="127.76.13.64"                   # both names below point here (every address of 127.0.0.0/8 is local)
REG_HOST="hub.registry"               # the registry: HTTP on port 80 of ADDR, Bearer authentication like Docker Hub
AUTH_HOST="auth.hub.registry"         # its token service: HTTP on port 5001 of ADDR (another name, like auth.docker.io for registry-1.docker.io)
CTD_VERSION="2.2.3"                   # the oldest 2.x with a fix this case depends on is 2.1.0 (headers of hosts.toml are sent to the token endpoint)
REG_VERSION="3.0.0"
case "$(uname -m)" in
    x86_64)         KARCH="amd64"; CTD_SHA="ca26ef5138f17b847bbeeec36d4bf5e002b54d25858197a870c125d57f44d32f"; REG_SHA="61c9a2c0d5981a78482025b6b69728521fbc78506d68b223d4a2eb825de5ca3d" ;;
    aarch64|arm64)  KARCH="arm64"; CTD_SHA="2942d72435b18610f7b69c1ddb74f99cef5c549425ff80d3e74f04e5e80db6a4"; REG_SHA="6c2ee1d135626fa42e0d6fb66a0e0f42e22439e5050087d04f4c5ff53655892e" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac
CTD_TGZ="containerd-$CTD_VERSION-linux-$KARCH.tar.gz"
REG_TGZ="registry_${REG_VERSION}_linux_${KARCH}.tar.gz"
CRICTL_VERSION="v1.34.0"
NS="bench76136482"                    # containerd namespace of the lab's own work (pushing the images); the CRI uses k8s.io

echo "[setup] checking the tools: python3, openssl, curl, tar, sudo, sha256sum, crictl..."
for c in python3 openssl curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${KARCH}.tar.gz" -o /tmp/crictl.tar.gz \
        || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
CRICTL_BIN="$(command -v crictl)"
echo "  host: $(uname -m), kernel $(uname -r), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null), $(crictl --version | head -1)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] that the two names are free and that $ADDR:80 and $ADDR:5001 are not in use..."
if grep -qE "(^|[[:space:]])($REG_HOST|$AUTH_HOST)([[:space:]]|\$)" /etc/hosts; then
    echo "[setup] ERROR: /etc/hosts already names $REG_HOST or $AUTH_HOST"; exit 1
fi
if sudo ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "^$ADDR:(80|5001)\$"; then
    echo "[setup] ERROR: $ADDR:80 or $ADDR:5001 is in use"; exit 1
fi

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

# a package is taken from the cache when its sha256 is right, else downloaded and checked
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if sudo test -f "$CACHE/$1" && echo "$3  $CACHE/$1" | sudo sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION and the registry $REG_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
sudo install -d -m 755 "$CACHE" "$LIB" "$LIB/bin" "$LIB/libexec" "$LIB/etc" "$LIB/etc/certs.d/$REG_HOST" "$LIB/root" "$LIB/registry/data" "$LIB/auth" "$RUN" "$RUN/state"
fetch "$CTD_TGZ" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/$CTD_TGZ" "$CTD_SHA"
fetch "$REG_TGZ" "https://github.com/distribution/distribution/releases/download/v${REG_VERSION}/$REG_TGZ" "$REG_SHA"
tar -xzf "$CACHE/$CTD_TGZ" -C "$WORK_DIR" bin/containerd bin/ctr bin/containerd-shim-runc-v2
for b in containerd ctr containerd-shim-runc-v2; do sudo install -m 755 -o root -g root "$WORK_DIR/bin/$b" "$LIB/libexec/$b"; done
rm -rf "$WORK_DIR/bin"
tar -xzf "$CACHE/$REG_TGZ" -C "$WORK_DIR" registry
sudo install -m 755 -o root -g root "$WORK_DIR/registry" "$LIB/libexec/registry"
rm -f "$WORK_DIR/registry"
echo "  $("$LIB/libexec/containerd" --version | head -1), $("$LIB/libexec/registry" --version | head -1)"

echo "[setup] the two names in /etc/hosts (marked), the account of the registry (made now, readable by root only)..."
printf '%s %s %s # %s\n' "$ADDR" "$REG_HOST" "$AUTH_HOST" "$CASE_ID" | sudo tee -a /etc/hosts >/dev/null
PW="pw-$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
sudo sh -c 'umask 077; printf "{\"user\": \"hubuser\", \"password\": \"%s\"}\n" "$1" > "$2"' _ "$PW" "$LIB/account.json"
sudo chmod 600 "$LIB/account.json"

echo "[setup] the token service (Python, signs with a key of the lab): Basic credentials at the token endpoint give a token with pull/push on the repositories, no credentials give a token with no access, wrong ones 401..."
sudo openssl genrsa -out "$LIB/auth/key.pem" 2048 2>/dev/null
sudo chmod 600 "$LIB/auth/key.pem"
MOD=$(sudo openssl rsa -in "$LIB/auth/key.pem" -noout -modulus 2>/dev/null | sed 's/^Modulus=//')
sudo python3 - "$MOD" "$LIB/auth/jwks.json" <<'PYEOF'
import base64
import json
import sys

n = int(sys.argv[1], 16)
b = lambda x: base64.urlsafe_b64encode(x.to_bytes((x.bit_length() + 7) // 8, "big")).rstrip(b"=").decode()
json.dump({"keys": [{"kty": "RSA", "kid": "lab", "use": "sig", "alg": "RS256", "n": b(n), "e": b(65537)}]}, open(sys.argv[2], "w"))
PYEOF
sudo tee "$LIB/auth/tokensrv.py" >/dev/null <<'PYEOF'
"""tokensrv.py LIB ADDR PORT LOG : a Docker-Hub-like token endpoint for the registry of the lab (GET /token?service=...&scope=...)"""
import base64
import hashlib
import json
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

lib, addr, port, logpath = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
account = json.load(open(lib + "/account.json"))
log = open(logpath, "a", buffering=1)


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):          # Docker Hub's token endpoint also takes the OAuth form; this one does not (clients fall back to GET)
        self.send_response(405)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        url = urlparse(self.path)
        if url.path != "/token":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        q = parse_qs(url.query)
        auth = self.headers.get("Authorization", "")
        scheme = auth.split(" ", 1)[0] if auth else "none"
        user = None
        if auth.startswith("Basic "):
            try:
                u, p = base64.b64decode(auth[6:]).decode().split(":", 1)
                if u == account["user"] and p == account["password"]:
                    user = u
            except Exception:
                pass
        scopes = q.get("scope", [])
        result = "granted" if user else "anonymous"
        if auth and not user:
            result = "denied"
            log.write(json.dumps({"ts": time.time(), "authorization": scheme, "user": None, "result": result, "scope": scopes}) + "\n")
            body = json.dumps({"details": "incorrect username or password"}).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        access = []
        for s in scopes:
            kind, name, actions = s.split(":", 2)
            access.append({"type": kind, "name": name, "actions": [a for a in actions.split(",") if user]})
        now = int(time.time())
        head = b64(json.dumps({"typ": "JWT", "alg": "RS256", "kid": "lab"}).encode())
        claims = b64(json.dumps({"iss": "tokensrv", "sub": user or "", "aud": q.get("service", [""])[0], "exp": now + 300, "nbf": now - 5, "iat": now,
                                 "jti": hashlib.md5(str(time.time()).encode()).hexdigest(), "access": access}).encode())
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", lib + "/auth/key.pem"], input=(head + "." + claims).encode(), capture_output=True, check=True).stdout
        token = head + "." + claims + "." + b64(sig)
        log.write(json.dumps({"ts": time.time(), "authorization": scheme, "user": user, "result": result, "scope": scopes}) + "\n")
        body = json.dumps({"token": token, "access_token": token, "expires_in": 300}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer((addr, port), Handler).serve_forever()
PYEOF
sudo tee "$LIB/registry/config.yml" >/dev/null <<CEOF
version: 0.1
log:
  level: info
  accesslog:
    disabled: false
storage:
  filesystem:
    rootdirectory: $LIB/registry/data
http:
  addr: $ADDR:80
auth:
  token:
    realm: http://$AUTH_HOST:5001/token
    service: $REG_HOST
    issuer: tokensrv
    jwks: $LIB/auth/jwks.json
CEOF
sudo tee "$LIB/bin/hubctl" >/dev/null <<CTLEOF
#!/bin/bash
# hubctl start|stop|restart|status : the registry ($REG_HOST) and its token service ($AUTH_HOST) of this lab (needs root: it runs itself with sudo)
# logs: $RUN/registry.log (a line for every request of the registry), $RUN/token.log (a line for every token request)
[ "\$(id -u)" = 0 ] || exec sudo "\$0" "\$@"
LIB="$LIB"; RUN="$RUN"
alive() { local p; p=\$(cat "\$RUN/\$1.pid" 2>/dev/null) || return 1; [ -n "\$p" ] && tr '\0' ' ' 2>/dev/null < "/proc/\$p/cmdline" | grep -q -- "\$LIB/"; }
do_start() {
    alive registry || { setsid nohup "\$LIB/libexec/registry" serve "\$LIB/registry/config.yml" >>"\$RUN/registry.log" 2>&1 </dev/null & echo \$! > "\$RUN/registry.pid"; }
    alive token || { setsid nohup python3 "\$LIB/auth/tokensrv.py" "\$LIB" "$ADDR" 5001 "\$RUN/token.log" >>"\$RUN/token.err" 2>&1 </dev/null & echo \$! > "\$RUN/token.pid"; }
    for i in \$(seq 1 40); do curl -s -o /dev/null -m 2 "http://$ADDR/v2/" && curl -s -o /dev/null -m 2 "http://$ADDR:5001/token" && { echo "registry and token service started"; return 0; }; sleep 0.5; done
    echo "the registry or the token service did not come up"; return 1
}
do_stop() {
    for n in registry token; do
        if alive \$n; then p=\$(cat "\$RUN/\$n.pid"); kill -TERM "\$p"; for i in \$(seq 1 20); do kill -0 "\$p" 2>/dev/null || break; sleep 0.25; done; kill -0 "\$p" 2>/dev/null && kill -KILL "\$p"; fi
        rm -f "\$RUN/\$n.pid"
    done
    echo "registry and token service stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) alive registry && alive token && echo "registry and token service are running" || { echo "not (both) running"; exit 3; } ;;
    *) echo "usage: hubctl start|stop|restart|status"; exit 2 ;;
esac
CTLEOF

echo "[setup] containerd's configuration (version 3: the registry settings are read from the hosts directory $LIB/etc/certs.d), its hosts file for $REG_HOST, the control scripts..."
sudo tee "$LIB/etc/config.toml" >/dev/null <<TEOF
version = 3

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '$LIB/etc/certs.d'
TEOF
sudo tee "$LIB/etc/certs.d/$REG_HOST/hosts.toml" >/dev/null <<TEOF
server = "http://$REG_HOST"

[host."http://$REG_HOST"]
  capabilities = ["pull", "resolve"]
TEOF
sudo tee "$LIB/bin/containerdctl" >/dev/null <<CTLEOF
#!/bin/bash
# containerdctl start|stop|restart|status : the private containerd $CTD_VERSION of this lab, CRI on (needs root: it runs itself with sudo)
[ "\$(id -u)" = 0 ] || exec sudo "\$0" "\$@"
RUN="$RUN"; LIB="$LIB"
PIDFILE="\$RUN/containerd.pid"
running() {
    local p; p=\$(cat "\$PIDFILE" 2>/dev/null) || return 1
    [ -n "\$p" ] && tr '\0' ' ' 2>/dev/null < "/proc/\$p/cmdline" | grep -q -- "--address \$RUN/containerd.sock"
}
case "\$1" in
    start)
        running && { echo "containerd is already running"; exit 0; }
        mkdir -p "\$RUN/state"
        rm -f "\$RUN/containerd.sock" "\$RUN/containerd.sock.ttrpc"
        PATH="\$LIB/libexec:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" setsid nohup "\$LIB/libexec/containerd" --config "\$LIB/etc/config.toml" --root "\$LIB/root" --state "\$RUN/state" --address "\$RUN/containerd.sock" --log-level info >"\$RUN/containerd.log" 2>&1 </dev/null &
        echo \$! > "\$PIDFILE"
        for i in \$(seq 1 60); do [ -S "\$RUN/containerd.sock" ] && "\$LIB/libexec/ctr" -a "\$RUN/containerd.sock" version >/dev/null 2>&1 && { echo "containerd started"; exit 0; }; sleep 0.5; done
        echo "containerd did not come up (see \$RUN/containerd.log)"; exit 1 ;;
    stop)
        running || { echo "containerd is not running"; exit 0; }
        p=\$(cat "\$PIDFILE"); kill -TERM "\$p"
        for i in \$(seq 1 40); do kill -0 "\$p" 2>/dev/null || break; sleep 0.5; done
        kill -0 "\$p" 2>/dev/null && kill -KILL "\$p"
        rm -f "\$PIDFILE"; echo "containerd stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) running && echo "containerd is running (pid \$(cat "\$PIDFILE"))" || { echo "containerd is not running"; exit 3; } ;;
    *) echo "usage: containerdctl start|stop|restart|status"; exit 2 ;;
esac
CTLEOF
sudo tee "$LIB/bin/crictl" >/dev/null <<CTLEOF
#!/bin/bash
# crictl aimed at the private containerd (needs root: it runs itself with sudo)
[ "\$(id -u)" = 0 ] || exec sudo "\$0" "\$@"
exec "$CRICTL_BIN" --runtime-endpoint unix://$RUN/containerd.sock --image-endpoint unix://$RUN/containerd.sock --timeout 120s "\$@"
CTLEOF
sudo tee "$LIB/bin/ctr" >/dev/null <<CTLEOF
#!/bin/bash
# ctr aimed at the private containerd (needs root: it runs itself with sudo)
[ "\$(id -u)" = 0 ] || exec sudo "\$0" "\$@"
exec "$LIB/libexec/ctr" --address "$RUN/containerd.sock" "\$@"
CTLEOF
sudo chmod 755 "$LIB/bin/hubctl" "$LIB/bin/containerdctl" "$LIB/bin/crictl" "$LIB/bin/ctr"

echo "[setup] starting the registry, the token service and containerd..."
sudo "$LIB/bin/hubctl" start
sudo "$LIB/bin/containerdctl" start

echo "[setup] the repository team/app: one image (tag v1), pushed with the account (the push is the only thing the lab does with the credentials, and it removes its own copy)..."
sudo tee "$STATE_DIR/mkarchive.py" >/dev/null <<'PYEOF'
"""mkarchive.py OUT REF NONCE ARCH : a one-layer docker archive (docker save format) with one file, /nonce"""
import hashlib
import io
import json
import sys
import tarfile

out, ref, nonce, arch = sys.argv[1:5]


def sha(b):
    return hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    data = (nonce + "\n").encode()
    ti = tarfile.TarInfo("nonce")
    ti.size, ti.mode, ti.mtime = len(data), 0o644, 1700000000
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "config": {},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps([{"Config": sha(config) + ".json", "RepoTags": [ref], "Layers": [sha(layer) + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for name, payload in (("manifest.json", manifest), (sha(config) + ".json", config), (sha(layer) + "/layer.tar", layer)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(payload), 1700000000
        t.addfile(ti, io.BytesIO(payload))
PYEOF
REF="$REG_HOST/team/app:v1"
sudo python3 "$STATE_DIR/mkarchive.py" "$WORK_DIR/app.tar" "$REF" "setup-$(python3 -c 'import secrets; print(secrets.token_hex(8))')" "$KARCH"
sudo "$LIB/bin/ctr" -n "$NS" images import "$WORK_DIR/app.tar" >/dev/null
sudo "$LIB/bin/ctr" -n "$NS" images push --plain-http --user "hubuser:$PW" "$REF" >/dev/null 2>&1 || { echo "[setup] ERROR: could not push $REF to the registry"; exit 1; }
sudo "$LIB/bin/ctr" -n "$NS" images rm --sync "$REF" >/dev/null
sudo rm -f "$WORK_DIR/app.tar"
sudo sh -c "cd \"$LIB\" && sha256sum etc/config.toml registry/config.yml auth/tokensrv.py auth/jwks.json account.json > \"$STATE_DIR/lab.sha\""
sudo sh -c ": > \"$RUN/token.log\""

echo "[setup] ready: containerd $CTD_VERSION (CRI, hosts directory $LIB/etc/certs.d), registry $REG_HOST and token service $AUTH_HOST, repository team/app with the tag v1"
