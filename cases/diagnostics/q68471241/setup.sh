#!/bin/bash
set -e

CASE_ID="bench68471241"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                          # the node's programs (releases/, node/current -> one of them), its configuration (etc/), certificates, storage, the control scripts
RUN="/run/$CASE_ID"                              # CRI-O's socket, state and log
CACHE="/var/cache/$CASE_ID"                      # the downloaded and checked CRI-O and registry releases (kept by cleanup.sh)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only)
ETC="$LIB/etc"
REG="127.68.47.1:5000"                           # the registry the images come from (setup only; every address of 127.0.0.0/8 is local)
PORT=5555                                        # metrics_port of the question
RELEASES="v1.20.7 v1.21.0 v1.22.4"               # on the disk of the node: the first one runs (the question's is 1.20.3, which is not published as a static bundle), the others are what an upgrade can use
START_REL="v1.20.7"
REG_VERSION="3.0.0"                              # distribution/distribution
RUNC_VERSION="v1.1.12"                           # opencontainers/runc: the OCI runtime of every release (the arm64 bundles of CRI-O 1.20 to 1.22 have no runc, only an old crun that cannot run here)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"
        REG_SHA="61c9a2c0d5981a78482025b6b69728521fbc78506d68b223d4a2eb825de5ca3d"
        RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8"
        PINS="v1.20.7 66ef0de23e6b16acd24407e22ccf0d8ca0c91f3fe3f5546332accc96d3d59f25
v1.21.0 75d1aefd93d9b6eea9627d20c1a8b65307e10396b7c28d440308bb351ca041bb
v1.22.4 14835043e7ab96a06d471a0f19fb0a34260eae8ff58da44aea6dd2902731aa01" ;;
    aarch64|arm64)  KARCH="arm64"
        REG_SHA="6c2ee1d135626fa42e0d6fb66a0e0f42e22439e5050087d04f4c5ff53655892e"
        RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8"
        PINS="v1.20.7 01ddfcdb9a820fdd4798882883ca2cb27fed82a0c61ea45a27f1aa0b793dbba1
v1.21.0 a3dc626ecd8ecd0561b6219abe49e5e64d86e5d45a1a6647eb10d9fd0dd3c8f7
v1.22.4 211aab47bfbef6d355d50db447f372576a9372247df8db422dfe04291e889c8a" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac
RUNC_FILE="runc.$KARCH.$RUNC_VERSION"
REG_TGZ="registry_${REG_VERSION}_linux_${KARCH}.tar.gz"
PAUSE_REF="$REG/pause:1"                         # the sandbox image: made here, pulled once by setup, never again
APP_REF="$REG/app:1"                             # the image of the lab's workload

echo "[setup] checking the tools: python3, openssl, curl, tar, gcc, sudo, sha256sum..."
for c in python3 openssl curl tar sudo sha256sum; do
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

echo "[setup] checking that the metrics port $PORT and the registry address $REG are free..."
python3 - "$PORT" <<'PYEOF' || { echo "[setup] ERROR: port $PORT is in use on this host (the question's metrics_port; stop what uses it)"; exit 1; }
import socket
import sys

for fam, addr in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
    try:
        s = socket.socket(fam, socket.SOCK_STREAM)
    except OSError:
        continue                                    # no IPv6 on this host
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)         # a port in TIME_WAIT after a previous run is free (Go listeners set this too)
    try:
        s.bind((addr, int(sys.argv[1])))
    except OSError as e:
        if e.errno == 98:
            sys.exit(1)
    finally:
        s.close()
PYEOF
if curl -s --noproxy '*' --max-time 2 -o /dev/null "http://$REG/v2/" 2>/dev/null; then
    echo "[setup] ERROR: something already listens on $REG"; exit 1
fi

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$LIB/bin" "$LIB/releases" "$LIB/node" "$LIB/crio" "$LIB/registry/data" "$LIB/certs" "$LIB/workload" "$ETC" "$ETC/crio.conf.d" "$RUN"
# cgroups CRI-O makes below "crio" (the containers it runs): what is there now stays, cleanup.sh removes only what the case's CRI-O adds
sudo sh -c "find /sys/fs/cgroup -type d \\( -name crio -o -path '*/crio/*' -o -name 'crio-conmon-*' \\) 2>/dev/null | sort > '$LIB/cgroups.before'"

# a release is taken from the cache when its sha256 is right, else downloaded and checked
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 900 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] CRI-O $RELEASES, runc $RUNC_VERSION and the registry $REG_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
sudo install -d -m 755 "$CACHE"
for v in $RELEASES; do
    sha=$(echo "$PINS" | awk -v v="$v" '$1 == v {print $2}')
    fetch "cri-o.$KARCH.$v.tar.gz" "https://storage.googleapis.com/cri-o/artifacts/cri-o.$KARCH.$v.tar.gz" "$sha"
    tar -xzf "$CACHE/cri-o.$KARCH.$v.tar.gz" -C "$WORK_DIR" cri-o/bin
    sudo install -d -m 755 "$LIB/releases/$v"
    for b in crio conmon pinns crictl; do sudo install -m 755 -o root -g root "$WORK_DIR/cri-o/bin/$b" "$LIB/releases/$v/$b"; done
    rm -rf "$WORK_DIR/cri-o"
done
fetch "$RUNC_FILE" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
for v in $RELEASES; do sudo install -m 755 -o root -g root "$CACHE/$RUNC_FILE" "$LIB/releases/$v/oci-runtime"; done
fetch "$REG_TGZ" "https://github.com/distribution/distribution/releases/download/v${REG_VERSION}/$REG_TGZ" "$REG_SHA"
tar -xzf "$CACHE/$REG_TGZ" -C "$WORK_DIR" registry
sudo install -m 755 -o root -g root "$WORK_DIR/registry" "$LIB/bin/registry"
rm -f "$WORK_DIR/registry"
sudo install -m 755 -o root -g root "$LIB/releases/v1.22.4/crictl" "$LIB/bin/crictl"
sudo ln -sfn "$LIB/releases/$START_REL" "$LIB/node/current"
for v in $RELEASES; do echo "  $v: $("$LIB/releases/$v/crio" --version 2>/dev/null | head -1), runtime $("$LIB/releases/$v/oci-runtime" --version 2>/dev/null | head -1)"; done

echo "[setup] the registry (plain HTTP, no login) for the two images, started here and stopped at the end of setup..."
cat <<CEOF | sudo tee "$LIB/registry/config.yml" >/dev/null
version: 0.1
log:
  level: warn
storage:
  filesystem:
    rootdirectory: $LIB/registry/data
http:
  addr: $REG
CEOF
sudo sh -c 'setsid -f bash -c '"'"'echo $$ > "$1"; exec "$2" serve "$3" >>"$4" 2>&1 </dev/null'"'"' _ "$1" "$2" "$3" "$4" </dev/null >/dev/null 2>&1' _ "$RUN/registry.pid" "$LIB/bin/registry" "$LIB/registry/config.yml" "$RUN/registry.log"
CODE=""
for _ in $(seq 1 30); do
    CODE=$(curl -s --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code}' "http://$REG/v2/" 2>/dev/null || true)
    [ "$CODE" = "200" ] && break
    sleep 1
done
[ "$CODE" = "200" ] || { echo "[setup] ERROR: the registry does not answer 200 on /v2/ (got '$CODE')"; sudo tail -5 "$RUN/registry.log" 2>/dev/null; exit 1; }

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

/* the program of the lab's workload: says the nonce of its image (the file /nonce) every two seconds */
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
NONCE="n-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
sudo python3 - "$REG" "$STATE_DIR" "$NONCE" <<'PYEOF'
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile
import urllib.request

REG, ST, NONCE = sys.argv[1:4]
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))      # the registry is local: never through a proxy of the environment


def reg(method, path, data=None, headers=None):
    r = urllib.request.Request("http://%s%s" % (REG, path), data=data, method=method, headers=headers or {})
    with OPENER.open(r, timeout=30) as resp:
        return resp.status, resp.headers, resp.read()


def push_image(repo, tag, binary, nonce, cmd):
    """what 'docker push' does, with the plain distribution API: one layer (the program and /nonce), one config, a schema 2 manifest"""
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
            raise RuntimeError("push of a blob to %s failed: %d" % (repo, st))
    m = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
                    "config": {"mediaType": "application/vnd.docker.container.image.v1+json", "size": len(cfg), "digest": dig(cfg)},
                    "layers": [{"mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip", "size": len(layer), "digest": dig(layer)}]}).encode()
    st, _, body = reg("PUT", "/v2/%s/manifests/%s" % (repo, tag), m, {"Content-Type": "application/vnd.docker.distribution.manifest.v2+json"})
    if st != 201:
        raise RuntimeError("push of the manifest of %s:%s failed: %d" % (repo, tag, st))


push_image("pause", "1", ST + "/pause", "pause", "/pause")
push_image("app", "1", ST + "/marker", NONCE, "/marker")
PYEOF
echo "  -> $PAUSE_REF and $APP_REF are in the registry"

echo "[setup] the certificates of the metrics endpoint (the question's cert.crt and key.crt, signed by a CA of this lab; SAN localhost and 127.0.0.1)..."
(
    cd "$WORK_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 3650 -subj "/CN=bench68471241 metrics CA" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -keyout key.crt -out srv.csr -subj "/CN=crio-metrics" >/dev/null 2>&1
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > san.ext
    openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out cert.crt -days 3650 -extfile san.ext >/dev/null 2>&1
    openssl verify -CAfile ca.crt cert.crt >/dev/null
)
sudo install -m 644 -o root -g root "$WORK_DIR/ca.crt" "$WORK_DIR/cert.crt" "$WORK_DIR/key.crt" "$LIB/certs/"
sudo install -m 600 -o root -g root "$WORK_DIR/ca.key" "$STATE_DIR/ca.key"
rm -f "$WORK_DIR"/ca.key "$WORK_DIR"/ca.srl "$WORK_DIR"/ca.crt "$WORK_DIR"/cert.crt "$WORK_DIR"/key.crt "$WORK_DIR"/srv.csr "$WORK_DIR"/san.ext

echo "[setup] CRI-O: its own root, state and socket; the programs come from node/current; the metrics drop-in is the question's (cert and key set); the sandbox image is local..."
cat <<CEOF | sudo tee "$ETC/crio.conf" >/dev/null
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
conmon = "$LIB/node/current/conmon"
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
default_runtime = "runc"
pinns_path = "$LIB/node/current/pinns"
container_exits_dir = "$RUN/exits"
container_attach_socket_dir = "$RUN"
namespaces_dir = "$RUN/ns"

[crio.runtime.runtimes.runc]
runtime_path = "$LIB/bin/runc-wrap"
runtime_root = "$RUN/runc"
monitor_path = "$LIB/node/current/conmon"
monitor_cgroup = "pod"

[crio.image]
pause_image = "$PAUSE_REF"
signature_policy = "$ETC/policy.json"

[crio.network]
network_dir = "$ETC/cni/"
plugin_dirs = ["$LIB/cni-bin/"]
CEOF
cat <<CEOF | sudo tee "$ETC/crio.conf.d/01-metrics.conf" >/dev/null
[crio.metrics]
enable_metrics = true
metrics_port = $PORT
metrics_cert = "$LIB/certs/cert.crt"
metrics_key = "$LIB/certs/key.crt"
CEOF
sudo install -d -m 755 "$ETC/cni" "$LIB/cni-bin"
sudo sh -c 'echo "{\"default\": [{\"type\": \"insecureAcceptAnything\"}]}" > "$1"' _ "$ETC/policy.json"
printf '[storage]\ndriver = "overlay"\nrunroot = "%s"\ngraphroot = "%s"\n' "$RUN/storage" "$LIB/crio/storage" | sudo tee "$ETC/storage.conf" >/dev/null
cat <<CEOF | sudo tee "$ETC/registries.conf" >/dev/null
unqualified-search-registries = []

[[registry]]
location = "$REG"
insecure = true
CEOF
# the OCI runtime of the release (runc or crun), without the hugetlb limits the kubelet asks for (a kernel with cgroup v1 and no hugetlb controller to write to cannot set them) and, only on a host that cannot
# grant it (no CAP_SYS_RESOURCE: some sandboxes; the flag file is made by setup), without the negative oom_score_adj of the sandboxes (-998), which the runtime could not write
if sudo sh -c 'echo -998 > /proc/self/oom_score_adj' 2>/dev/null; then
    echo "[setup] this host can lower oom_score_adj"
else
    echo "[setup] this host cannot lower oom_score_adj (no CAP_SYS_RESOURCE): the runtime wrapper drops the negative oomScoreAdj of the sandboxes"
    sudo touch "$ETC/no-negative-oom"
fi
cat <<CEOF | sudo tee "$LIB/bin/runc-wrap" >/dev/null
#!/bin/sh
for a in "\$@"; do [ "\$a" = create ] && C=1; done
if [ -n "\$C" ]; then
    B=""; P=""
    for a in "\$@"; do if [ "\$P" = "--bundle" ] || [ "\$P" = "-b" ]; then B="\$a"; fi; P="\$a"; done
    [ -n "\$B" ] && python3 -c "
import json, os, sys
p = sys.argv[1] + '/config.json'
c = json.load(open(p))
ch = c.get('linux', {}).get('resources', {}).pop('hugepageLimits', None) is not None
if os.path.exists('$ETC/no-negative-oom') and c.get('process', {}).get('oomScoreAdj', 0) < 0:
    del c['process']['oomScoreAdj']
    ch = True
if ch:
    json.dump(c, open(p, 'w'))
" "\$B"
fi
exec "\$(dirname "\$0")/../node/current/oci-runtime" "\$@"
CEOF
sudo chmod 755 "$LIB/bin/runc-wrap"
cat <<CEOF | sudo tee "$LIB/bin/crioctl" >/dev/null
#!/bin/bash
# how this machine's CRI-O is started and stopped: crioctl start|stop|restart|status
# It runs the crio of $LIB/node/current (a link to one of the releases in $LIB/releases), with $ETC/crio.conf and the drop-ins
# in $ETC/crio.conf.d. CRI-O reads its configuration and the program is chosen only when it starts. Its log is $RUN/crio.log.
PIDF="$RUN/crio.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "crio is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec env HOME=/root CONTAINER_REGISTRIES_CONF="$ETC/registries.conf" CONTAINERS_STORAGE_CONF="$ETC/storage.conf" "$LIB/node/current/crio" --config "$ETC/crio.conf" --config-dir "$ETC/crio.conf.d" --log-level info >>"\$2" 2>&1 </dev/null' _ "\$PIDF" "$RUN/crio.log" </dev/null >/dev/null 2>&1
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
cat <<CEOF | sudo tee "$LIB/bin/scrape" >/dev/null
#!/bin/bash
# what the monitoring does: GET https://localhost:$PORT/metrics, trusting only the CA of this lab ($LIB/certs/ca.crt)
exec curl -sS --max-time 10 --cacert "$LIB/certs/ca.crt" "https://localhost:$PORT\${1:-/metrics}"
CEOF
sudo chmod 755 "$LIB/bin/scrape"
cat <<CEOF | sudo tee "$LIB/workload/pod.json" >/dev/null
{
  "metadata": {"name": "@NAME@", "namespace": "lab", "uid": "@NAME@-uid", "attempt": 1},
  "log_directory": "$RUN/log/@NAME@",
  "linux": {"security_context": {"namespace_options": {"network": 2}}}
}
CEOF
cat <<CEOF | sudo tee "$LIB/workload/container.json" >/dev/null
{
  "metadata": {"name": "@NAME@"},
  "image": {"image": "$APP_REF"},
  "log_path": "0.log",
  "linux": {}
}
CEOF
cat <<CEOF | sudo tee "$LIB/bin/run-workload" >/dev/null
#!/bin/bash
# run-workload NAME: runs the lab's workload (one pod with the host network and one container of $APP_REF, which says its marker every
# two seconds) as pod and container NAME on this node's CRI-O; prints the id of the container. Remove it with: crictl rmp -f POD
NAME="\${1:?usage: run-workload NAME}"
CR=("$LIB/bin/crictl" -r "unix://$RUN/crio.sock" -i "unix://$RUN/crio.sock" --timeout 120s)
mkdir -p "$RUN/log/\$NAME"
sed "s/@NAME@/\$NAME/g" "$LIB/workload/pod.json" > "$RUN/log/\$NAME.pod.json"
sed "s/@NAME@/\$NAME/g" "$LIB/workload/container.json" > "$RUN/log/\$NAME.ctr.json"
POD=\$("\${CR[@]}" runp "$RUN/log/\$NAME.pod.json") || exit 1
CTR=\$("\${CR[@]}" create "\$POD" "$RUN/log/\$NAME.ctr.json" "$RUN/log/\$NAME.pod.json") || exit 1
"\${CR[@]}" start "\$CTR" >/dev/null || exit 1
echo "\$CTR"
CEOF
sudo chmod 755 "$LIB/bin/run-workload"

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
"${CRI[@]}" pull "$PAUSE_REF" >/dev/null || { echo "[setup] ERROR: CRI-O could not pull the sandbox image"; exit 1; }
"${CRI[@]}" pull "$APP_REF" >/dev/null || { echo "[setup] ERROR: CRI-O could not pull the image of the workload"; exit 1; }
echo "  -> the images are in the node's storage; the registry is not needed any more"
sudo sh -c 'kill -TERM "$(cat "$1")" 2>/dev/null; for _ in $(seq 1 20); do kill -0 "$(cat "$1")" 2>/dev/null || break; sleep 0.5; done; kill -KILL "$(cat "$1")" 2>/dev/null; true' _ "$RUN/registry.pid"
sudo rm -rf "$LIB/registry" "$LIB/bin/registry" "$RUN/registry.pid"

echo "[setup] the record of the lab (checksums of everything the oracle expects to be unchanged, the truth about the images and the certificate)..."
APP_ID=$("${CRI[@]}" inspecti -o json "$APP_REF" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])')
PAUSE_ID=$("${CRI[@]}" inspecti -o json "$PAUSE_REF" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])')
CERT_FP=$(sudo openssl x509 -in "$LIB/certs/cert.crt" -noout -fingerprint -sha256 | cut -d= -f2)
sudo python3 - "$STATE_DIR" "$NONCE" "$APP_ID" "$PAUSE_ID" "$CERT_FP" "$PORT" "$APP_REF" "$PAUSE_REF" <<'PYEOF'
import json
import sys
import time

st, nonce, app_id, pause_id, fp, port, app_ref, pause_ref = sys.argv[1:9]
json.dump({"nonce": nonce, "app_id": app_id, "pause_id": pause_id, "cert_fp": fp, "port": int(port), "app_ref": app_ref, "pause_ref": pause_ref,
           "setup_time": time.time()}, open(st + "/truth.json", "w"))
PYEOF
sudo sh -c "cd / && { find '${LIB#/}/releases' '${LIB#/}/bin' '${ETC#/}' '${LIB#/}/workload' -type f ! -path '${ETC#/}/crio.conf.d/*'; echo '${LIB#/}/certs/ca.crt'; } | sort | xargs sha256sum > '$STATE_DIR/lab.sha'"
sudo touch -d '1 second ago' "$STATE_DIR/truth.json"

echo "[setup] what the monitoring sees now (scrape = GET https://localhost:$PORT/metrics with the lab's CA; plain HTTP for comparison)..."
echo "  scrape: $(sudo "$LIB/bin/scrape" 2>&1 | head -c 200)"
echo "  http:   $(curl -s --max-time 5 --noproxy '*' "http://127.0.0.1:$PORT/metrics" | head -2 | tr '\n' ' ' | head -c 160)"
echo "[setup] done. Node: CRI-O $START_REL ($RUN/crio.sock, metrics on port $PORT, drop-in $ETC/crio.conf.d/01-metrics.conf); releases in $LIB/releases; control scripts in $LIB/bin."
