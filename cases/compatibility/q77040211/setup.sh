#!/bin/bash
set -e

CASE_ID="bench77040211"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                          # the four nodes, the registry (binary, configuration, data), the lab CA, nodectl
RUN="/run/$CASE_ID"                              # the registry's request log
CACHE="/var/cache/$CASE_ID"                      # the downloaded and checked registry release (kept by cleanup.sh)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): truth.json, the lab CA's key, the programs
NODES="node1 node2 node3 node4"
ADDR="10.77.40.11"                               # the registry's address: a /32 alias of lo (every node reaches it; it is not 127.x)
PORT=5000
ALIAS="lo:b77040"
PAUSE_REF="$CASE_ID.local/pause:1"               # the sandbox image of the pods, imported offline into every node
REG_VERSION="3.0.0"                              # distribution/distribution; the sha256 below are the ones the project publishes next to each release asset (.tar.gz.sha256)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64"; REG_SHA="61c9a2c0d5981a78482025b6b69728521fbc78506d68b223d4a2eb825de5ca3d" ;;
    aarch64|arm64)  ARCH="arm64"; REG_SHA="6c2ee1d135626fa42e0d6fb66a0e0f42e22439e5050087d04f4c5ff53655892e" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the tools: containerd, ctr, runc, python3, curl, tar, openssl, gcc, sudo..."
for c in containerd ctr runc python3 curl tar sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
for c in openssl gcc; do
    if ! command -v "$c" >/dev/null 2>&1; then
        sudo -E apt-get update -qq
        sudo -E apt-get install -y -qq "${APT_OPTS[@]}" openssl gcc libc6-dev
    fi
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c could not be installed"; exit 1; }
done
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
containerd --version
crictl --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking that port $PORT is free..."
python3 - "$PORT" <<'PYEOF' || { echo "[setup] ERROR: something already listens on port $PORT"; exit 1; }
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    sys.exit(1)
PYEOF

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

echo "[setup] the registry $REG_VERSION ($ARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
REG_TGZ="registry_${REG_VERSION}_linux_${ARCH}.tar.gz"
sudo install -d -m 755 "$CACHE"
if ! { [ -f "$CACHE/$REG_TGZ" ] && echo "$REG_SHA  $CACHE/$REG_TGZ" | sha256sum -c --quiet - 2>/dev/null; }; then
    sudo rm -f "$CACHE/$REG_TGZ"
    curl -fsSL --retry 3 -o "$WORK_DIR/$REG_TGZ" "https://github.com/distribution/distribution/releases/download/v${REG_VERSION}/${REG_TGZ}" \
        || { echo "[setup] ERROR: could not download the registry release"; exit 1; }
    echo "$REG_SHA  $WORK_DIR/$REG_TGZ" | sha256sum -c --quiet - || { echo "[setup] ERROR: the downloaded registry release does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$REG_TGZ" "$CACHE/$REG_TGZ"
    rm -f "$WORK_DIR/$REG_TGZ"
fi
sudo install -d -m 755 "$LIB" "$LIB/bin" "$LIB/pki" "$RUN"
sudo install -d -m 700 "$LIB/registry" "$LIB/registry/data"
sudo tar xzf "$CACHE/$REG_TGZ" -C "$WORK_DIR" registry
sudo install -m 755 "$WORK_DIR/registry" "$LIB/bin/registry"
sudo rm -f "$WORK_DIR/registry"
"$LIB/bin/registry" --version

echo "[setup] the lab CA and the registry's certificate (valid for $ADDR)..."
sudo openssl req -x509 -newkey rsa:2048 -nodes -keyout "$STATE_DIR/ca.key" -out "$LIB/pki/ca.crt" -days 30 -subj "/CN=$CASE_ID lab CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" 2>/dev/null
sudo chmod 644 "$LIB/pki/ca.crt"
sudo openssl req -newkey rsa:2048 -nodes -keyout "$LIB/registry/registry.key" -out "$STATE_DIR/registry.csr" -subj "/CN=registry.$CASE_ID.local" 2>/dev/null
printf "subjectAltName=IP:%s,DNS:registry.%s.local\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n" \
    "$ADDR" "$CASE_ID" | sudo tee "$STATE_DIR/registry.ext" >/dev/null
sudo openssl x509 -req -in "$STATE_DIR/registry.csr" -CA "$LIB/pki/ca.crt" -CAkey "$STATE_DIR/ca.key" -CAcreateserial -CAserial "$STATE_DIR/ca.srl" \
    -out "$LIB/registry/registry.crt" -days 30 -extfile "$STATE_DIR/registry.ext" >/dev/null 2>&1
sudo chmod 600 "$LIB/registry/registry.key"
sudo openssl verify -CAfile "$LIB/pki/ca.crt" "$LIB/registry/registry.crt" >/dev/null || { echo "[setup] ERROR: the registry certificate does not verify against the lab CA"; exit 1; }

echo "[setup] the programs: argus (prints a nonce and the salt of its image, then waits) and the sandbox, compiled static so that nothing is pulled from a public registry..."
cat > "$WORK_DIR/argus.c" <<'CEOF'
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
CEOF
cat > "$WORK_DIR/pause.c" <<'CEOF'
#include <unistd.h>

/* the sandbox ("pause") image of the node: the only file of the image */
int main(void) {
    for (;;) pause();
}
CEOF
gcc -static -Os -s -w -o "$WORK_DIR/argus-bin" "$WORK_DIR/argus.c"
gcc -static -Os -s -w -o "$WORK_DIR/pause-bin" "$WORK_DIR/pause.c"
rm -f "$WORK_DIR/argus.c" "$WORK_DIR/pause.c"
cat > "$WORK_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py push BASEURL REPO TAG BINARY ENTRY [SALT] : build a Docker image (one layer with BINARY as /ENTRY and, when SALT is given, a file /salt holding it: a new SALT is
a new image with new digests) and push it to the registry with the plain distribution API (what `docker push` does)
   mkimg.py tar OUT REF BINARY ENTRY [SALT]          : build the same into an OCI archive (for ctr images import)
Prints the digests as JSON."""
import gzip
import hashlib
import io
import json
import os
import sys
import ssl
import tarfile
import urllib.request

DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def build(binary, entry, salt=""):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        data = open(binary, "rb").read()
        ti = tarfile.TarInfo(entry)
        ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        t.addfile(ti, io.BytesIO(data))
        if salt:
            sd = (salt + "\n").encode()
            si = tarfile.TarInfo("salt")
            si.size, si.mode, si.mtime = len(sd), 0o644, 1700000000
            si.uid = si.gid = 0
            si.uname = si.gname = ""
            t.addfile(si, io.BytesIO(sd))
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
    """returns (status, Location header)"""
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": ctype,
                                                                         "User-Agent": "docker/20.10.21 (setup)"})
    ctx = ssl.create_default_context(cafile=os.environ.get("BENCH_CA")) if url.startswith("https") else None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx))   # the sandbox exports the agent's proxy variables
    with opener.open(req, timeout=30) as r:
        return r.status, r.headers.get("Location", "")


def upload(base, repo, blob):
    """what `docker push` does: POST starts an upload, PUT ...?digest= sends the blob"""
    status, loc = http("POST", "%s/v2/%s/blobs/uploads/" % (base, repo), b"", "application/octet-stream")
    assert status == 202, status
    if loc.startswith("/"):
        loc = base + loc
    status, _ = http("PUT", loc + ("&" if "?" in loc else "?") + "digest=" + sha(blob), blob, "application/octet-stream")
    assert status == 201, status


mode = sys.argv[1]
if mode == "push":
    base, repo, tag, binary, entry = sys.argv[2:7]
    layer_gz, config, manifest = build(binary, entry, sys.argv[7] if len(sys.argv) > 7 else "")
    for blob in (layer_gz, config):
        upload(base, repo, blob)
    assert http("PUT", "%s/v2/%s/manifests/%s" % (base, repo, tag), manifest, DOCKER_MANIFEST)[0] == 201
    print(truth(layer_gz, config, manifest))
else:
    out, ref, binary, entry = sys.argv[2:6]
    layer_gz, config, manifest = build(binary, entry, sys.argv[6] if len(sys.argv) > 6 else "")
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
cat > "$WORK_DIR/patch_config.py" <<'PYEOF'
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
PYEOF
sudo mv "$WORK_DIR/argus-bin" "$WORK_DIR/pause-bin" "$WORK_DIR/mkimg.py" "$WORK_DIR/patch_config.py" "$STATE_DIR/"
sudo python3 "$STATE_DIR/mkimg.py" tar "$STATE_DIR/pause.tar" "$PAUSE_REF" "$STATE_DIR/pause-bin" pause >/dev/null

echo "[setup] the registry address $ADDR (an alias of lo) and the registry on HTTPS at $ADDR:$PORT..."
cat > "$WORK_DIR/registry.yml" <<EOF
version: 0.1
log:
  level: info
  formatter: text
  accesslog:
    disabled: false
storage:
  filesystem:
    rootdirectory: $LIB/registry/data
  delete:
    enabled: true
http:
  addr: $ADDR:$PORT
  secret: $CASE_ID
  tls:
    certificate: $LIB/registry/registry.crt
    key: $LIB/registry/registry.key
EOF
sudo install -m 600 "$WORK_DIR/registry.yml" "$LIB/registry/config.yml"
rm -f "$WORK_DIR/registry.yml"
cat > "$WORK_DIR/alias.py" <<'PYEOF'
#!/usr/bin/env python3
"""alias.py add|del|has IFACE:LABEL IP : the lab's registry address (10.66.64.45) as an alias of the loopback interface (no `ip` binary
needed; a /32, so no route of the range appears). The address is not in 127.0.0.0/8: containerd never treats it as a loopback registry, which it would pull from over plain HTTP without any setting."""
import fcntl
import socket
import struct
import sys

SIOCSIFADDR, SIOCSIFFLAGS, SIOCSIFNETMASK = 0x8916, 0x8914, 0x891C
IFF_UP, IFF_RUNNING = 0x1, 0x40


def has(ip):
    for ln in open("/proc/net/fib_trie"):
        if ln.strip() == "|-- " + ip:
            return True
    return False


def ifreq(name, family=socket.AF_INET, addr=None):
    return struct.pack("16sH2x4s8x", name.encode(), family, socket.inet_aton(addr)) if addr else struct.pack("16sH14x", name.encode(), 0)


def main(cmd, name, ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if cmd == "has":
        sys.exit(0 if has(ip) else 1)
    if cmd == "add":
        if has(ip):
            sys.exit("%s is already an address of this host" % ip)
        fcntl.ioctl(s, SIOCSIFADDR, ifreq(name, addr=ip))
        fcntl.ioctl(s, SIOCSIFNETMASK, ifreq(name, addr="255.255.255.255"))
        fcntl.ioctl(s, SIOCSIFFLAGS, struct.pack("16sH14x", name.encode(), IFF_UP | IFF_RUNNING))
    elif cmd == "del":
        try:
            fcntl.ioctl(s, SIOCSIFFLAGS, struct.pack("16sH14x", name.encode(), 0))
        except OSError:
            pass


main(*sys.argv[1:4])
PYEOF
sudo mv "$WORK_DIR/alias.py" "$STATE_DIR/alias.py"
sudo python3 "$STATE_DIR/alias.py" add "$ALIAS" "$ADDR" || { echo "[setup] ERROR: cannot add the address $ADDR to lo"; exit 1; }
sudo setsid -f bash -c 'exec "$1" serve "$2" > "$3" 2>&1 < /dev/null' _ "$LIB/bin/registry" "$LIB/registry/config.yml" "$RUN/registry.log"
for _ in $(seq 40); do curl -s --noproxy '*' --cacert "$LIB/pki/ca.crt" --max-time 2 -o /dev/null "https://$ADDR:$PORT/v2/" && break; sleep 0.5; done
curl -s --noproxy '*' --cacert "$LIB/pki/ca.crt" --max-time 2 -o /dev/null "https://$ADDR:$PORT/v2/" \
    || { echo "[setup] ERROR: the registry does not answer at https://$ADDR:$PORT/v2/"; sudo tail -5 "$RUN/registry.log"; exit 1; }

echo "[setup] the four nodes: a private containerd each (own root, state, socket, configuration and runc state), started by nodectl; the sandbox image is imported offline..."
cat > "$WORK_DIR/nodectl" <<'SHEOF'
#!/bin/bash
# nodectl start|stop|restart|status node1|node2|node3|node4|all
LIB=/var/lib/bench77040211
[ "$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
usage() { echo "usage: nodectl start|stop|restart|status node1|node2|node3|node4|all" >&2; exit 2; }
one() {
    local cmd=$1 n=$2 d=$LIB/$2
    local pidf=$d/containerd.pid sock=$d/run/containerd.sock
    local pid=""; [ -s "$pidf" ] && pid=$(cat "$pidf")
    local running=0; [ -n "$pid" ] && [ "$(cat /proc/$pid/comm 2>/dev/null)" = containerd ] && running=1
    case "$cmd" in
    start)
        [ "$running" = 1 ] && { echo "nodectl: $n is already running (pid $pid)"; return 0; }
        mkdir -p "$d/run" "$d/log"
        setsid -f bash -c 'echo $$ > "$1/containerd.pid"; exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin containerd --config "$1/etc/config.toml"' _ "$d" >> "$d/log/containerd.log" 2>&1 < /dev/null
        for _ in $(seq 60); do
            [ -S "$sock" ] && timeout 3 crictl -r "unix://$sock" -i "unix://$sock" version >/dev/null 2>&1 && { echo "nodectl: $n started (pid $(cat "$pidf"))"; return 0; }
            sleep 0.5
        done
        echo "nodectl: $n did not answer on $sock within 30 s; see $d/log/containerd.log" >&2; return 1 ;;
    stop)
        if [ "$running" = 1 ]; then
            kill -TERM "$pid" 2>/dev/null
            for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
        fi
        rm -f "$pidf" "$sock" "$sock.ttrpc"; echo "nodectl: $n stopped" ;;
    restart) one stop "$n"; one start "$n" ;;
    status) if [ "$running" = 1 ]; then echo "$n is running (pid $pid)"; else echo "$n is not running"; return 1; fi ;;
    esac
}
cmd=${1:-}; target=${2:-}
case "$cmd" in start|stop|restart|status) ;; *) usage ;; esac
case "$target" in
    node1|node2|node3|node4) one "$cmd" "$target" ;;
    all) rc=0; for n in node1 node2 node3 node4; do one "$cmd" "$n" || rc=1; done; exit $rc ;;
    *) usage ;;
esac
SHEOF
sudo install -m 755 "$WORK_DIR/nodectl" "$LIB/bin/nodectl"
rm -f "$WORK_DIR/nodectl"
for n in $NODES; do
    d="$LIB/$n"
    sudo install -d -m 755 "$d" "$d/etc" "$d/run" "$d/root" "$d/log" "$d/cni/bin" "$d/cni/net.d"
    containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$d/root" "$d/run" "$d/run/containerd.sock" "$d/cni" "$PAUSE_REF" | sudo tee "$d/etc/config.toml" >/dev/null
    sudo grep -q "$PAUSE_REF" "$d/etc/config.toml" || { echo "[setup] ERROR: could not set the sandbox image in the configuration of $n"; exit 1; }
    sudo "$LIB/bin/nodectl" start "$n" >/dev/null || { echo "[setup] ERROR: $n did not start"; sudo tail -8 "$d/log/containerd.log" 2>/dev/null; exit 1; }
    sudo ctr -a "$d/run/containerd.sock" -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the sandbox image into $n"; exit 1; }
done

echo "[setup] the image argus is built (one layer, a random salt) and pushed to the registry the way docker push does; the record of what is true is written..."
sudo python3 - "$LIB" "$STATE_DIR" "$WORK_DIR" "$ADDR:$PORT" "$PAUSE_REF" <<'PYEOF'
import json, os, subprocess, sys, secrets, hashlib, re
lib, state, work, reg, pause = sys.argv[1:6]
env = dict(os.environ, BENCH_CA=lib + "/pki/ca.crt")
salt = secrets.token_hex(6)
r = subprocess.run(["python3", state + "/mkimg.py", "push", "https://" + reg, "argus", "1", state + "/argus-bin", "argus", salt], env=env, capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("could not push the image: " + r.stderr[-300:])
t = json.loads(r.stdout.strip().splitlines()[-1])
t["salt"] = salt
t["ref"] = "%s/argus@%s" % (reg, t["manifest"])
def sha_file(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()
def find_pid(name, needle):
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                if open("/proc/%s/comm" % d).read().strip() == name and needle in open("/proc/%s/cmdline" % d, "rb").read().replace(b"\0", b" ").decode("latin-1"):
                    return int(d)
            except OSError:
                pass
    return 0
rp = find_pid("registry", lib + "/registry/config.yml")
if not rp:
    sys.exit("the registry is not running")
t["reg_pid"] = rp
t["reg_start"] = open("/proc/%d/stat" % rp).read().rsplit(")", 1)[1].split()[19]
t["reg_cfg_sha"] = sha_file(lib + "/registry/config.yml")
t["ctl_sha"] = sha_file(lib + "/bin/nodectl")
t["ca_sha"] = sha_file(lib + "/pki/ca.crt")
import ssl, socket
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
host, port = reg.split(":")
with socket.create_connection((host, int(port)), timeout=8) as s, ctx.wrap_socket(s) as w:
    t["cert_sha"] = hashlib.sha256(w.getpeercert(binary_form=True)).hexdigest()
t["pause"] = {}
for n in ("node1", "node2", "node3", "node4"):
    sock = "%s/%s/run/containerd.sock" % (lib, n)
    o = subprocess.run(["crictl", "-r", "unix://" + sock, "-i", "unix://" + sock, "inspecti", "-o", "json", pause], capture_output=True, text=True)
    try:
        t["pause"][n] = json.loads(o.stdout)["status"]["id"]
    except (ValueError, KeyError):
        sys.exit("the sandbox image is not in " + n)
json.dump(t, open(state + "/truth.json", "w"))
open(lib + "/argus.ref", "w").write(t["ref"] + "\n")
os.chmod(lib + "/argus.ref", 0o644)
print("lab up: registry pid %d at %s, image %s" % (rp, reg, t["ref"]))
PYEOF

echo "[setup] done. The four nodes cannot pull $ADDR:$PORT/argus: they do not trust the registry's certificate. The image to pull is in $LIB/argus.ref."
