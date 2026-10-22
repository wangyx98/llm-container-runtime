#!/bin/bash
set -e

CASE_ID="bench77827486"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                          # registry, CRI-O (programs, storage), k3s (program, data, kubelet root), CNI, the control scripts
RUN="/run/$CASE_ID"                              # CRI-O's configuration, socket and log; the registry's configuration and log; the logs of k3s
CACHE="/var/cache/$CASE_ID"                      # the downloaded and checked CRI-O, k3s and registry releases (kept by cleanup.sh)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): truth.json, the credentials, the programs of the images
ADDR="127.78.27.1"                               # both registry names point here (every address of 127.0.0.0/8 is local)
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
OWNED_MARKER="$LIB/host_dirs_owned"              # k3s' fixed directories are the case's own once this exists
CRIO_VERSION="v1.25.2"                           # the CRI-O of the question (static bundle, with conmon, pinns, runc, crictl and the CNI plugins)
K3S_VERSION="v1.26.4+k3s1"                       # the Kubernetes of the question; k3s runs on the CRI-O above as its container runtime
REG_VERSION="3.0.0"                              # distribution/distribution
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"; K3S_ASSET="k3s"
        K3S_SHA="ce3080b31854a4b17e598b010395f1cf28a1ded06bd0ec578355af79d3f83661"
        CRIO_SHA="2e8128a897ab4e608e7f958337705611ebb7d27e14189135439262588edfc738"
        REG_SHA="61c9a2c0d5981a78482025b6b69728521fbc78506d68b223d4a2eb825de5ca3d" ;;
    aarch64|arm64)  KARCH="arm64"; K3S_ASSET="k3s-arm64"
        K3S_SHA="532c1d260210c495db86c8e166a779d22cd2e08e789c65c6d1a4b12f008c2db2"
        CRIO_SHA="a5f77e13001794145d96306d0db779f0ff855a8d6e556e6a0e4a1f56b624b430"
        REG_SHA="6c2ee1d135626fa42e0d6fb66a0e0f42e22439e5050087d04f4c5ff53655892e" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac
CRIO_TGZ="cri-o.$KARCH.$CRIO_VERSION.tar.gz"
REG_TGZ="registry_${REG_VERSION}_linux_${KARCH}.tar.gz"
PAUSE_REF="mirror.registry/pause:1"              # the sandbox image: made here, pulled once by setup, never again

echo "[setup] checking the tools: python3, perl, curl, tar, gcc, sudo, sha256sum..."
for c in python3 perl curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
echo "  host: $(uname -m), kernel $(uname -r), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking this host has no k3s or kubelet state of its own (k3s keeps files in fixed places that this case manages),"
echo "[setup] that the two registry names are free and that $ADDR:80 is not in use..."
for d in /etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s; do
    [ ! -e "$d" ] || { echo "[setup] ERROR: $d exists: this host has its own k3s or kubelet state, the case would damage it"; exit 1; }
done
for c in k3s-server k3s-agent kubelet; do
    ! pgrep -x "$c" >/dev/null 2>&1 || { echo "[setup] ERROR: a $c process runs on this host: the case needs a host without k3s or a kubelet"; exit 1; }
done
for f in /run/containers/0/auth.json /root/.docker/config.json; do
    sudo test ! -e "$f" || { echo "[setup] ERROR: $f exists: CRI-O would read it (registry credentials of this host)"; exit 1; }
done
if grep -qE '(^|[[:space:]])(private|mirror)\.registry([[:space:]]|$)' /etc/hosts; then
    echo "[setup] ERROR: /etc/hosts already names private.registry or mirror.registry"; exit 1
fi
if curl -s --noproxy '*' --max-time 2 -o /dev/null "http://$ADDR:80/" 2>/dev/null; then
    echo "[setup] ERROR: something already listens on $ADDR:80"; exit 1
fi

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$LIB/bin" "$LIB/libexec" "$LIB/opt/crio" "$LIB/cni/bin" "$LIB/cni/net.d" "$LIB/registry/data" "$LIB/crio" "$RUN" "$RUN/crio.conf.d"
# the kubelet writes the logs of the Pods and containers into these two directories of the host: what is there now stays
for d in pods containers; do ls -A "/var/log/$d" 2>/dev/null | sudo tee "$LIB/logs.$d.before" >/dev/null || true; done
# cgroups CRI-O makes below "crio" (the containers it runs): what is there now stays, cleanup.sh removes only what the case's CRI-O adds
sudo sh -c "find /sys/fs/cgroup -type d \\( -name crio -o -path '*/crio/*' \\) 2>/dev/null | sort > '$LIB/cgroups.before'"
sudo touch "$OWNED_MARKER"

# a release is taken from the cache when its sha256 is right, else downloaded and checked
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 900 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] CRI-O $CRIO_VERSION, k3s $K3S_VERSION and the registry $REG_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
sudo install -d -m 755 "$CACHE"
fetch "$CRIO_TGZ" "https://storage.googleapis.com/cri-o/artifacts/$CRIO_TGZ" "$CRIO_SHA"
fetch "$K3S_ASSET-$K3S_VERSION" "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/$K3S_ASSET" "$K3S_SHA"
fetch "$REG_TGZ" "https://github.com/distribution/distribution/releases/download/v${REG_VERSION}/$REG_TGZ" "$REG_SHA"
tar -xzf "$CACHE/$CRIO_TGZ" -C "$WORK_DIR" cri-o/bin cri-o/cni-plugins
for b in crio conmon pinns runc crictl; do sudo install -m 755 -o root -g root "$WORK_DIR/cri-o/bin/$b" "$LIB/opt/crio/$b"; done
sudo install -m 755 -o root -g root "$LIB/opt/crio/crictl" "$LIB/bin/crictl"
for f in "$WORK_DIR"/cri-o/cni-plugins/*; do sudo install -m 755 -o root -g root "$f" "$LIB/cni/bin/"; done
rm -rf "$WORK_DIR/cri-o"
sudo install -m 755 -o root -g root "$CACHE/$K3S_ASSET-$K3S_VERSION" "$LIB/libexec/k3s"
tar -xzf "$CACHE/$REG_TGZ" -C "$WORK_DIR" registry
sudo install -m 755 -o root -g root "$WORK_DIR/registry" "$LIB/bin/registry"
rm -f "$WORK_DIR/registry"
echo "  $("$LIB/opt/crio/crio" --version | head -1), $("$LIB/libexec/k3s" --version | head -1), $("$LIB/bin/registry" --version | head -1)"

echo "[setup] the registry (HTTP, basic auth: a user and a password made now), the two names of it in /etc/hosts, its log..."
PW="pw-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
SALT="$(python3 -c 'import secrets; print("".join(secrets.choice("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") for _ in range(22)))')"
HASH="$(perl -e 'print crypt($ARGV[0], $ARGV[1])' "$PW" "\$2b\$05\$$SALT")"
echo "$HASH" | grep -q '^\$2b\$05\$' || { echo "[setup] ERROR: could not make a bcrypt hash for the registry"; exit 1; }
sudo sh -c 'umask 077; printf "{\"user\": \"labuser\", \"password\": \"%s\"}\n" "$1" > "$2"' _ "$PW" "$STATE_DIR/creds.json"
printf 'labuser:%s\n' "$HASH" | sudo tee "$LIB/registry/htpasswd" >/dev/null
cat <<CEOF | sudo tee "$LIB/registry/config.yml" >/dev/null
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
  htpasswd:
    realm: lab
    path: $LIB/registry/htpasswd
CEOF
cat <<CEOF | sudo tee "$LIB/bin/registryctl" >/dev/null
#!/bin/bash
# how the registry of this machine is started and stopped: registryctl start|stop|restart|status
# (it reads $LIB/registry/config.yml; its log, with a line for every request, is $RUN/registry.log)
PIDF="$RUN/registry.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "registry is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec "\$2" serve "\$3" >>"\$4" 2>&1 </dev/null' _ "\$PIDF" "$LIB/bin/registry" "$LIB/registry/config.yml" "$RUN/registry.log" </dev/null >/dev/null 2>&1
    echo "registry started"
}
do_stop() {
    alive || { echo "registry is not running"; return 0; }
    kill -TERM "\$(cat "\$PIDF")"
    for _ in \$(seq 1 30); do alive || break; sleep 0.5; done
    alive && kill -KILL "\$(cat "\$PIDF")"
    echo "registry stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid \$(cat "\$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: registryctl start|stop|restart|status"; exit 2 ;;
esac
CEOF
sudo chmod 755 "$LIB/bin/registryctl"
sudo sh -c 'printf "%s private.registry mirror.registry # bench77827486\n" "$1" >> /etc/hosts' _ "$ADDR"
sudo "$LIB/bin/registryctl" start >/dev/null
CODE=""
for _ in $(seq 1 30); do
    CODE=$(curl -s --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code}' "http://mirror.registry/v2/" 2>/dev/null || true)
    [ "$CODE" = "401" ] && break
    sleep 1
done
[ "$CODE" = "401" ] || { echo "[setup] ERROR: the registry does not answer 401 on /v2/ (got '$CODE')"; sudo tail -5 "$RUN/registry.log" 2>/dev/null; exit 1; }
echo "  -> registry up on $ADDR:80 as private.registry and mirror.registry, anonymous requests get 401"

echo "[setup] the programs of the images (static, built here: nothing is pulled from a public registry)..."
cat > "$WORK_DIR/pause.c" <<'CEOF'
#include <unistd.h>

/* the sandbox ("pause") image of the node: the only file of the image */
int main(void) {
    for (;;) pause();
}
CEOF
cat > "$WORK_DIR/marker.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

/* the program of the images: says the nonce of its image (the file /nonce) every two seconds */
int main(void) {
    char nonce[64] = {0};
    FILE *f = fopen("/nonce", "r");
    if (f) {
        if (!fgets(nonce, sizeof nonce, f)) nonce[0] = 0;
        fclose(f);
    }
    for (;;) {
        printf("marker=%s\n", nonce);
        fflush(stdout);
        sleep(2);
    }
}
CEOF
gcc -static -Os -s -w -o "$WORK_DIR/pause" "$WORK_DIR/pause.c"
gcc -static -Os -s -w -o "$WORK_DIR/marker" "$WORK_DIR/marker.c"
sudo install -m 755 -o root -g root "$WORK_DIR/pause" "$WORK_DIR/marker" "$STATE_DIR/"
rm -f "$WORK_DIR/pause" "$WORK_DIR/marker" "$WORK_DIR/pause.c" "$WORK_DIR/marker.c"
echo "[setup] the sandbox image mirror.registry/pause:1 and the image of the engineer's Pod, private.registry/team/app:v1 (the program prints a marker)..."
sudo python3 - "$WORK_DIR" <<'PYEOF'
import base64
import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request

CASE = "bench77827486"
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
WORK = sys.argv[1] if len(sys.argv) > 1 else "/tmp/" + CASE
ST = WORK + "/.bench"
CRIO_SOCK = RUN + "/crio.sock"
CRICTL = [LIB + "/bin/crictl", "-r", "unix://" + CRIO_SOCK, "-i", "unix://" + CRIO_SOCK, "--timeout", "120s"]
KUBECTL = [LIB + "/bin/kubectl"]
NODE = CASE
ORIG = "private.registry"       # the name of the images (what the Pods say, what the secret is for)
MIRROR = "mirror.registry"      # where registries.conf sends it
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))      # the registry is local: never through a proxy of the environment


def run(argv, timeout=100, input=None):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp", input=input, stdin=None if input is not None else subprocess.DEVNULL)


def short(text, n=200):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= n else text[:n - 3] + "..."


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def sha_file(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()
    except OSError:
        return None


def wait_for(fn, timeout, step=1.0):
    end = time.time() + timeout
    while True:
        v = fn()
        if v:
            return v
        if time.time() >= end:
            return None
        time.sleep(step)


def truth():
    return json.load(open(ST + "/truth.json"))


def creds():
    return json.load(open(ST + "/creds.json"))


def basic(user, pw):
    return "Basic " + base64.b64encode(("%s:%s" % (user, pw)).encode()).decode()


def reg(method, path, data=None, headers=None, auth="good", host=MIRROR):
    """one request to the registry: auth is 'good', 'bad' (wrong password) or None; returns (status, headers, body)"""
    h = dict(headers or {})
    if auth:
        c = creds()
        h["Authorization"] = basic(c["user"], c["password"] if auth == "good" else "not-the-password")
    r = urllib.request.Request("http://%s%s" % (host, path), data=data, method=method, headers=h)
    try:
        with OPENER.open(r, timeout=20) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def push_image(repo, tag, binary, nonce, cmd):
    """what 'docker push' does, with the plain distribution API: one layer (the program and /nonce), one config, a schema 2 manifest; returns the manifest digest"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        d = open(binary, "rb").read()
        ti = tarfile.TarInfo(os.path.basename(cmd))
        ti.mode, ti.size = 0o755, len(d)
        t.addfile(ti, io.BytesIO(d))
        n = nonce.encode()
        ti = tarfile.TarInfo("nonce")
        ti.size = len(n)
        t.addfile(ti, io.BytesIO(n))
    raw = buf.getvalue()
    layer = gzip.compress(raw)
    dig = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()
    cfg = json.dumps({"architecture": {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64"), "os": "linux", "config": {"Cmd": [cmd]},
                      "rootfs": {"type": "layers", "diff_ids": [dig(raw)]}}).encode()
    for blob in (layer, cfg):
        st, hd, _ = reg("POST", "/v2/%s/blobs/uploads/" % repo)
        loc = hd["Location"]
        loc = loc[loc.index("/v2/"):]
        st, hd, body = reg("PUT", loc + ("&" if "?" in loc else "?") + "digest=" + dig(blob), blob, {"Content-Type": "application/octet-stream"})
        if st not in (201, 202):
            raise RuntimeError("push of a blob to %s failed: %d %s" % (repo, st, body[:100]))
    m = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
                    "config": {"mediaType": "application/vnd.docker.container.image.v1+json", "size": len(cfg), "digest": dig(cfg)},
                    "layers": [{"mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip", "size": len(layer), "digest": dig(layer)}]}).encode()
    st, _, body = reg("PUT", "/v2/%s/manifests/%s" % (repo, tag), m, {"Content-Type": "application/vnd.docker.distribution.manifest.v2+json"})
    if st != 201:
        raise RuntimeError("push of the manifest of %s:%s failed: %d %s" % (repo, tag, st, body[:100]))
    return dig(m)


def kv(line):
    return {k: v.strip('"') for k, v in re.findall(r'(\S+?)=("(?:[^"\\]|\\.)*"|\S+)', line)}


def reg_log_size():
    try:
        return os.path.getsize(RUN + "/registry.log")
    except OSError:
        return 0


def reg_log_since(offset):
    """what the registry logged after offset: the authorized requests (host, uri, user, method), the access-log lines (method, path, status, user agent)
    and the set of every host name a request carried"""
    with open(RUN + "/registry.log", "rb") as f:
        f.seek(offset)
        text = f.read().decode("utf-8", "replace")
    authorized, access, hosts = [], [], set()
    for line in text.splitlines():
        if "http.request.host=" in line:
            hosts.add(kv(line).get("http.request.host", ""))
        if 'msg="authorized request"' in line:
            d = kv(line)
            authorized.append({"host": d.get("http.request.host", ""), "uri": d.get("http.request.uri", ""), "user": d.get("auth.user.name", ""), "method": d.get("http.request.method", "")})
        m = re.match(r'^\S+ - \S* \[[^\]]*\] "(\S+) (\S+) HTTP/[\d.]+" (\d+) \d+ "[^"]*" "([^"]*)"', line)
        if m:
            access.append({"method": m.group(1), "path": m.group(2), "status": int(m.group(3)), "ua": m.group(4)})
    return authorized, access, hosts


def pod_json(ns, name):
    r = run(KUBECTL + ["-n", ns, "get", "pod", name, "-o", "json"])
    try:
        return json.loads(r.stdout) if r.returncode == 0 else None
    except ValueError:
        return None


def waiting_message(p):
    try:
        w = p["status"]["containerStatuses"][0]["state"]["waiting"]
        return w.get("reason", ""), w.get("message", "")
    except (KeyError, IndexError, TypeError):
        return "", ""


def pod_events(ns, name):
    r = run(KUBECTL + ["-n", ns, "get", "events", "--field-selector", "involvedObject.name=" + name, "-o", "jsonpath={range .items[*]}{.reason}: {.message}{\"\\n\"}{end}"])
    return r.stdout


def container_id(pod_name, ns):
    r = run(CRICTL + ["ps", "-a", "-q", "--label", "io.kubernetes.pod.name=" + pod_name, "--label", "io.kubernetes.pod.namespace=" + ns])
    return (r.stdout.split() or [None])[0]

push_image("pause", "1", ST + "/pause", "pause", "/pause")
push_image("team/app", "v1", ST + "/marker", "v1", "/marker")
PYEOF

echo "[setup] CRI-O: its own root, state and socket; registries.conf sends private.registry to mirror.registry (the question's rewrite); the sandbox image is local; no registry credentials of its own..."
cat <<CEOF | sudo tee "$RUN/crio.conf" >/dev/null
[crio]
root = "$LIB/crio/storage"
runroot = "$RUN/storage"
storage_driver = "overlay"
log_dir = "$RUN/pods"
version_file = "$RUN/version"
clean_shutdown_file = "$LIB/crio/clean.shutdown"

[crio.api]
listen = "$RUN/crio.sock"

[crio.runtime]
conmon = "$LIB/opt/crio/conmon"
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
default_runtime = "runc"
pinns_path = "$LIB/opt/crio/pinns"
container_exits_dir = "$RUN/exits"
container_attach_socket_dir = "$RUN"
namespaces_dir = "$RUN/ns"

[crio.runtime.runtimes.runc]
runtime_path = "$LIB/bin/runc-wrap"
runtime_root = "$RUN/runc"
monitor_path = "$LIB/opt/crio/conmon"
monitor_cgroup = "pod"

[crio.image]
pause_image = "$PAUSE_REF"
signature_policy = "$RUN/policy.json"

[crio.network]
network_dir = "$LIB/cni/net.d/"
plugin_dirs = ["$LIB/cni/bin/"]
CEOF
sudo sh -c 'echo "{\"default\": [{\"type\": \"insecureAcceptAnything\"}]}" > "$1"' _ "$RUN/policy.json"
printf '[storage]\ndriver = "overlay"\nrunroot = "%s"\ngraphroot = "%s"\n' "$RUN/storage" "$LIB/crio/storage" | sudo tee "$RUN/storage.conf" >/dev/null
cat <<CEOF | sudo tee "$RUN/registries.conf" >/dev/null
unqualified-search-registries = []

[[registry]]
prefix = "private.registry"
location = "mirror.registry"
insecure = true
CEOF
printf '{"cniVersion": "0.3.1", "name": "bench", "type": "bridge", "bridge": "bench0", "isGateway": true, "ipMasq": false, "hairpinMode": true, "ipam": {"type": "host-local", "ranges": [[{"subnet": "10.77.27.0/24"}]]}}\n' | sudo tee "$LIB/cni/net.d/10-bench.conf" >/dev/null
# runc of the bundle, without the hugetlb limits the kubelet asks for (a kernel with cgroup v1 and no hugetlb controller to write to cannot set them)
cat <<'CEOF' | sudo tee "$LIB/bin/runc-wrap" >/dev/null
#!/bin/sh
for a in "$@"; do [ "$a" = create ] && C=1; done
if [ -n "$C" ]; then
    B=""; P=""
    for a in "$@"; do if [ "$P" = "--bundle" ] || [ "$P" = "-b" ]; then B="$a"; fi; P="$a"; done
    [ -n "$B" ] && python3 -c "
import json, sys
p = sys.argv[1] + '/config.json'
c = json.load(open(p))
if c.get('linux', {}).get('resources', {}).pop('hugepageLimits', None) is not None:
    json.dump(c, open(p, 'w'))
" "$B"
fi
exec "$(dirname "$0")/../opt/crio/runc" "$@"
CEOF
sudo chmod 755 "$LIB/bin/runc-wrap"
cat <<CEOF | sudo tee "$LIB/bin/crioctl" >/dev/null
#!/bin/bash
# how this machine's CRI-O is started and stopped: crioctl start|stop|restart|status
# CRI-O reads $RUN/crio.conf (and the drop-ins in $RUN/crio.conf.d) and $RUN/registries.conf only when it starts
# (SIGHUP reloads only some settings); its home directory is /root, its log $RUN/crio.log
PIDF="$RUN/crio.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "crio is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec env HOME=/root CONTAINER_REGISTRIES_CONF="$RUN/registries.conf" CONTAINERS_STORAGE_CONF="$RUN/storage.conf" "$LIB/opt/crio/crio" --config "$RUN/crio.conf" --config-dir "$RUN/crio.conf.d" --log-level info >"\$2" 2>&1 </dev/null' _ "\$PIDF" "$RUN/crio.log" </dev/null >/dev/null 2>&1
    echo "crio started"
}
do_stop() {
    alive || { echo "crio is not running"; return 0; }
    kill -TERM "\$(cat "\$PIDF")"
    for _ in \$(seq 1 60); do alive || break; sleep 0.5; done
    alive && kill -KILL "\$(cat "\$PIDF")"
    echo "crio stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid \$(cat "\$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: crioctl start|stop|restart|status"; exit 2 ;;
esac
CEOF
sudo chmod 755 "$LIB/bin/crioctl"
sudo "$LIB/bin/crioctl" start >/dev/null
CRI=(sudo "$LIB/bin/crictl" -r "unix://$RUN/crio.sock" -i "unix://$RUN/crio.sock" --timeout 120s)
for _ in $(seq 1 60); do
    [ -S "$RUN/crio.sock" ] && "${CRI[@]}" version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! "${CRI[@]}" version >/dev/null 2>&1; then
    echo "[setup] ERROR: CRI-O did not come up; last log lines:"
    sudo tail -20 "$RUN/crio.log" 2>/dev/null || true
    exit 1
fi
echo "  -> CRI-O $("${CRI[@]}" version | awk '/RuntimeVersion/ {print $2}') up on $RUN/crio.sock"
PWD_NOW="$(sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["password"])' "$STATE_DIR/creds.json")"
"${CRI[@]}" pull --creds "labuser:$PWD_NOW" "$PAUSE_REF" >/dev/null || { echo "[setup] ERROR: CRI-O could not pull the sandbox image"; exit 1; }

echo "[setup] k3s $K3S_VERSION on this CRI-O (configuration $K3S_CONFIG), and the scripts k3sctl and kubectl..."
sudo mkdir -p /etc/rancher/k3s
cat <<CEOF | sudo tee "$K3S_CONFIG" >/dev/null
# configuration of the Kubernetes of this machine
data-dir: $LIB/k3s
https-listen-port: 16443
node-name: $CASE_ID
container-runtime-endpoint: unix://$RUN/crio.sock
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
  - root-dir=$LIB/kubelet
  - cgroup-driver=cgroupfs
  - cgroups-per-qos=false
  - enforce-node-allocatable=
  - make-iptables-util-chains=false
CEOF
cat <<CEOF | sudo tee "$LIB/bin/k3sctl" >/dev/null
#!/bin/bash
# how k3s is started and stopped on this machine: k3sctl start|stop|restart|status
# (k3s reads its options from $K3S_CONFIG; its log is $RUN/k3s.log)
PIDF="$RUN/k3s.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "k3s is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec env K3S_DATA_DIR="$LIB/k3s" "\$2" server >>"\$3" 2>&1 </dev/null' _ "\$PIDF" "$LIB/libexec/k3s" "$RUN/k3s.log" </dev/null >/dev/null 2>&1
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
cat <<CEOF | sudo tee "$LIB/bin/kubectl" >/dev/null
#!/bin/bash
# the kubectl of this machine's Kubernetes
exec env KUBECONFIG=/etc/rancher/k3s/k3s.yaml K3S_DATA_DIR="$LIB/k3s" "$LIB/libexec/k3s" kubectl "\$@"
CEOF
sudo chmod 755 "$LIB/bin/k3sctl" "$LIB/bin/kubectl"
echo "[setup] starting k3s. Waiting for the node $CASE_ID to be Ready..."
sudo "$LIB/bin/k3sctl" start >/dev/null
KC="sudo $LIB/bin/kubectl"
READY=""
for _ in $(seq 1 90); do
    READY=$($KC get node "$CASE_ID" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ "$READY" = "True" ] && break
    sleep 2
done
if [ "$READY" != "True" ]; then
    echo "[setup] ERROR: the node $CASE_ID did not become Ready; last log lines of k3s:"
    sudo tail -5 "$RUN/k3s.log" 2>/dev/null | cut -c1-200
    exit 1
fi
echo "  -> node $CASE_ID Ready, container runtime $($KC get node "$CASE_ID" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}'), kubelet $($KC get node "$CASE_ID" -o jsonpath='{.status.nodeInfo.kubeletVersion}')"

echo "[setup] the engineer's namespace my-ns, the secret registry-secret (the credentials for private.registry) and the Pod pod from the question..."
$KC create namespace my-ns >/dev/null
for _ in $(seq 1 60); do
    $KC -n my-ns get serviceaccount default >/dev/null 2>&1 && break
    sleep 1
done
sudo python3 - "$STATE_DIR" "$LIB/secret.yaml" <<'PYEOF'
import base64
import json
import sys

c = json.load(open(sys.argv[1] + "/creds.json"))
cfg = {"auths": {"private.registry": {"username": c["user"], "password": c["password"], "auth": base64.b64encode(("%s:%s" % (c["user"], c["password"])).encode()).decode()}}}
open(sys.argv[2], "w").write("""apiVersion: v1
kind: Secret
metadata:
  name: registry-secret
  namespace: my-ns
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: %s
""" % base64.b64encode(json.dumps(cfg).encode()).decode())
PYEOF
sudo chmod 600 "$LIB/secret.yaml"
$KC apply -f "$LIB/secret.yaml" >/dev/null
cat <<CEOF | sudo tee "$LIB/pod.yaml" >/dev/null
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    run: pod
  name: pod
  namespace: my-ns
spec:
  hostNetwork: true
  containers:
    - image: private.registry/team/app:v1
      name: pod
  imagePullSecrets:
    - name: registry-secret
CEOF
sudo rm -f "$LIB/secret.yaml"
$KC apply -f "$LIB/pod.yaml" >/dev/null || { echo "[setup] ERROR: could not create the Pod"; exit 1; }
echo "[setup] waiting for the Pod's first failed pull..."
SEEN=""
for i in $(seq 1 60); do
    MSG=$($KC -n my-ns get pod pod -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null || true)
    case "$MSG" in *"unauthorized: authentication required"*) SEEN=1; break ;; esac
    if [ "$i" = 30 ]; then    # a Pod that has not even tried by now is made again, once
        $KC -n my-ns delete pod pod --wait=true >/dev/null 2>&1 || true
        $KC apply -f "$LIB/pod.yaml" >/dev/null || true
    fi
    sleep 2
done
if [ -z "$SEEN" ]; then
    echo "[setup] ERROR: the Pod my-ns/pod does not fail with 'unauthorized: authentication required':"
    $KC -n my-ns describe pod pod 2>&1 | tail -12 | cut -c1-300
    sudo tail -5 "$RUN/crio.log" 2>/dev/null | cut -c1-300
    exit 1
fi

echo "[setup] recording what is true now..."
sudo python3 - "$STATE_DIR" "$LIB" "$RUN" <<'PYEOF'
import hashlib
import json
import subprocess
import sys

state, lib, run = sys.argv[1:4]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
pid = lambda p: int(open(p).read())
start = lambda p: open("/proc/%d/stat" % p).read().rsplit(")", 1)[1].split()[19]
rp, kp = pid(run + "/registry.pid"), pid(run + "/crio.pid")
secret = subprocess.run([lib + "/bin/kubectl", "-n", "my-ns", "get", "secret", "registry-secret", "-o", "jsonpath={.data}"], capture_output=True, text=True).stdout
json.dump({
    "registry_pid": rp, "registry_start": start(rp),
    "registry_config_sha": sha(lib + "/registry/config.yml"), "htpasswd_sha": sha(lib + "/registry/htpasswd"),
    "registries_conf_sha": sha(run + "/registries.conf"),
    "crio_sha": sha(lib + "/opt/crio/crio"), "runc_sha": sha(lib + "/opt/crio/runc"),
    "secret_sha": hashlib.sha256(secret.encode()).hexdigest(),
}, open(state + "/truth.json", "w"), indent=1)
PYEOF
echo "[setup] done. Registry http://private.registry and http://mirror.registry (the same one, basic auth), CRI-O $CRIO_VERSION with the rewrite private.registry -> mirror.registry, Kubernetes $K3S_VERSION; the Pod my-ns/pod cannot pull."
