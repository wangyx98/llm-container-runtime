#!/bin/bash
set -e

CASE_ID="bench53435138"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                          # the node: containerd (programs, data), the kubelet (program, configuration, manifests, root dir), kubeletctl, the Jenkins workspace
RUN="/run/$CASE_ID"                              # sockets, pid files and logs of the daemons
CACHE="/var/cache/$CASE_ID"                      # the downloaded and checked kubelet and Docker packages (kept by cleanup.sh)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): truth.json, the images, the job program
K8S_VERSION="v1.23.17"                           # a kubelet of the years of the question (containerd is its runtime through the CRI)
DOCKER_VERSION="20.10.24"                        # the static Docker package: dockerd and the docker CLI of the DinD image, containerd 1.6.20 (the node's runtime) and runc 1.1.5
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"; DARCH="x86_64"
        KUBELET_SHA="588dde06e2515601380787cb5fcb07ae3d3403130e1a5556b013b7b7fb4ab230"
        DOCKER_SHA="ab91092320a87691a1eaf0225b48585db9c69cff0ed4b0f569f744ff765515e3" ;;
    aarch64|arm64)  KARCH="arm64"; DARCH="aarch64"
        KUBELET_SHA="95e25ee4d2f34f628ba42685c6ae1ba6efdf86f2e76b5cceb0b48de4d66522a7"
        DOCKER_SHA="aa73e8b07a6086d05a14729eb02c9b0810c81c1924c1908034e8de807a0d2fe7" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac
CRICTL_VERSION="v1.34.0"
PAUSE_REF="$CASE_ID.local/pause:1"
AGENT_REF="$CASE_ID.local/agent:1"
DIND_REF="$CASE_ID.local/dind:1"
SOCK_SRC="$RUN/containerd.sock"                  # what the Jenkins Pod mounts as /var/run/docker.sock (the question)

echo "[setup] checking the tools: python3, curl, tar, gcc, sudo, sha256sum..."
for c in python3 curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${KARCH}.tar.gz" -o /tmp/crictl.tar.gz \
        || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
echo "  host: $(uname -m), kernel $(uname -r), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null), $(crictl --version | head -1)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

# a package is taken from the cache when its sha256 is right, else downloaded and checked
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] Kubernetes $K8S_VERSION kubelet and Docker $DOCKER_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
sudo install -d -m 755 "$CACHE"
fetch "kubelet-$K8S_VERSION-$KARCH" "https://dl.k8s.io/release/$K8S_VERSION/bin/linux/$KARCH/kubelet" "$KUBELET_SHA"
fetch "docker-$DOCKER_VERSION-$DARCH.tgz" "https://download.docker.com/linux/static/stable/$DARCH/docker-$DOCKER_VERSION.tgz" "$DOCKER_SHA"
sudo install -d -m 755 "$LIB" "$LIB/opt" "$LIB/bin" "$LIB/etc" "$LIB/containerd" "$LIB/docker" "$LIB/cni/bin" "$LIB/cni/net.d" "$LIB/kubelet" "$LIB/kubelet/manifests" "$RUN" "$RUN/docker-exec" "$RUN/containerd"
sudo tar xzf "$CACHE/docker-$DOCKER_VERSION-$DARCH.tgz" -C "$LIB/opt"
sudo install -m 755 "$CACHE/kubelet-$K8S_VERSION-$KARCH" "$LIB/opt/kubelet"
sudo chown -R root:root "$LIB/opt"
D="$LIB/opt/docker"
echo "  $("$LIB/opt/kubelet" --version), $("$D/dockerd" --version), $("$D/containerd" --version | cut -d' ' -f1-3), $("$D/runc" --version | head -1)"

echo "[setup] the programs (static, built here: nothing is pulled from a registry) and three images: the sandbox image, the Jenkins agent (a docker CLI) and the DinD image (dockerd, containerd, runc, a docker CLI and an entry point like the one of docker:dind)..."
cat > "$WORK_DIR/pause.c" <<'CEOF'
#include <unistd.h>

/* the sandbox ("pause") image of the node: the only file of the image */
int main(void) {
    for (;;) pause();
}
CEOF
cat > "$WORK_DIR/idle.c" <<'CEOF'
#include <signal.h>
#include <unistd.h>

static void bye(int sig) { _exit(0); }

int main(void) {
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    for (;;) pause();
}
CEOF
cat > "$WORK_DIR/job.c" <<'CEOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* the program of the Jenkins job: prints its nonce and the salt of the build context; with "hold" it then waits (a running container) */
int main(int argc, char **argv) {
    char salt[128] = "none";
    FILE *f = fopen("/salt", "r");
    setvbuf(stdout, NULL, _IONBF, 0);
    if (f) {
        if (fgets(salt, sizeof salt, f)) salt[strcspn(salt, "\r\n")] = 0;
        fclose(f);
    }
    printf("job nonce=%s salt=%s\n", argc > 1 ? argv[1] : "none", salt);
    if (argc > 2 && !strcmp(argv[2], "hold")) for (;;) pause();
    return 0;
}
CEOF
cat > "$WORK_DIR/dockerd-entrypoint.sh" <<'CEOF'
#!/bin/sh
# entry point of the DinD image (the logic of docker:dind's dockerd-entrypoint.sh, without TLS and without a bridge network): dockerd of this container
# listens on unix:///var/run/docker.sock, and on tcp://127.0.0.1:2375 when DOCKER_TLS_CERTDIR is set to the empty string; further arguments go to dockerd.
set -e
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then      # cgroup v2: no process may stay in the cgroup that enables controllers for its children
    mkdir -p /sys/fs/cgroup/init
    for p in $(cat /sys/fs/cgroup/cgroup.procs); do echo "$p" > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || :; done
    for c in $(cat /sys/fs/cgroup/cgroup.controllers); do echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || :; done
fi
set -- --host=unix:///var/run/docker.sock "$@"
if [ "${DOCKER_TLS_CERTDIR+set}" = set ] && [ -z "$DOCKER_TLS_CERTDIR" ]; then
    set -- --host=tcp://127.0.0.1:2375 "$@"
fi
exec dockerd --data-root=/var/lib/docker --bridge=none --iptables=false --ip-forward=false --userland-proxy=false --exec-opt native.cgroupdriver=cgroupfs "$@"
CEOF
cat > "$WORK_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py OUT REF ROOTDIR PATHENV ENTRYPOINT...  : a one-layer Docker-format image of ROOTDIR as an OCI archive (for ctr images import)"""
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

out, ref, root, pathenv = sys.argv[1:5]
entry = sys.argv[5:]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
M = "application/vnd.docker.distribution.manifest.v2+json"


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for d, dirs, files in os.walk(root):
        dirs.sort()
        for n in sorted(dirs + files):
            p = os.path.join(d, n)
            ti = t.gettarinfo(p, arcname=os.path.relpath(p, root))
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            ti.mtime = 1700000000
            if ti.isreg():
                with open(p, "rb") as f:
                    t.addfile(ti, f)
            else:
                t.addfile(ti)
layer = buf.getvalue()
gz = io.BytesIO()
with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
    g.write(layer)
layer_gz = gz.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Env": [pathenv], "Entrypoint": entry, "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": M,
                       "config": {"mediaType": "application/vnd.docker.container.image.v1+json", "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip", "digest": sha(layer_gz), "size": len(layer_gz)}]},
                      separators=(",", ":")).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": M, "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    def add(name, data):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(data), 1700000000
        t.addfile(ti, io.BytesIO(data))
    add("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
    add("index.json", index)
    for dg, data in ((sha(layer_gz), layer_gz), (sha(config), config), (sha(manifest), manifest)):
        add("blobs/sha256/" + dg.split(":")[1], data)
PYEOF
gcc -static -Os -s -w -o "$WORK_DIR/pause-bin" "$WORK_DIR/pause.c"
gcc -static -Os -s -w -o "$WORK_DIR/idle-bin" "$WORK_DIR/idle.c"
gcc -static -Os -s -w -o "$WORK_DIR/job-bin" "$WORK_DIR/job.c"
DEFPATH="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
add_tool() {    # $1 = root, $2 = a program of this machine; it is copied with the libraries it needs (ldd)
    local p real l
    p="$(command -v "$2" 2>/dev/null)" || return 0
    real="$(readlink -f "$p")"
    mkdir -p "$1$(dirname "$real")"
    cp -a "$real" "$1$real"
    [ "$(basename "$real")" = "$2" ] || ln -sf "$(basename "$real")" "$1/usr/bin/$2"
    for l in $(ldd "$real" 2>/dev/null | grep -o '/[^ ]*'); do
        mkdir -p "$1$(dirname "$l")"
        cp -aL "$l" "$1$l"
    done
}
mkroot() {      # $1 = root: the skeleton of a small root file system
    mkdir -p "$1/usr/bin" "$1/usr/local/bin" "$1/tmp" "$1/etc" "$1/proc" "$1/sys" "$1/dev" "$1/run" "$1/var/lib"
    chmod 1777 "$1/tmp"
    ln -s usr/bin "$1/bin"
    ln -s ../run "$1/var/run"
    echo "root:x:0:0:root:/root:/bin/sh" > "$1/etc/passwd"
    printf 'root:x:0:\ndocker:x:999:\n' > "$1/etc/group"
    cp "$WORK_DIR/idle-bin" "$1/usr/local/bin/idle"
    for t in sh ls cat mkdir grep sleep id env cp rm mv touch ps head tail readlink sha256sum seq; do add_tool "$1" "$t"; done
}
P="$WORK_DIR/pause-root"; A="$WORK_DIR/agent-root"; I="$WORK_DIR/dind-root"
mkdir -p "$P"; cp "$WORK_DIR/pause-bin" "$P/pause"
mkroot "$A"; mkdir -p "$A/home/jenkins/agent"; cp "$D/docker" "$A/usr/local/bin/docker"
mkroot "$I"; for b in dockerd containerd containerd-shim-runc-v2 runc docker docker-init; do cp "$D/$b" "$I/usr/local/bin/$b"; done
install -m 755 "$WORK_DIR/dockerd-entrypoint.sh" "$I/usr/local/bin/dockerd-entrypoint.sh"
python3 "$WORK_DIR/mkimg.py" "$WORK_DIR/pause.tar" "$PAUSE_REF" "$P" "$DEFPATH" /pause
python3 "$WORK_DIR/mkimg.py" "$WORK_DIR/agent.tar" "$AGENT_REF" "$A" "$DEFPATH" /usr/local/bin/idle
python3 "$WORK_DIR/mkimg.py" "$WORK_DIR/dind.tar" "$DIND_REF" "$I" "$DEFPATH" /usr/local/bin/dockerd-entrypoint.sh
sudo mv "$WORK_DIR/job-bin" "$STATE_DIR/job"
sudo mv "$WORK_DIR/pause.tar" "$WORK_DIR/agent.tar" "$WORK_DIR/dind.tar" "$STATE_DIR/"
rm -rf "$P" "$A" "$I" "$WORK_DIR"/*.c "$WORK_DIR/mkimg.py" "$WORK_DIR/dockerd-entrypoint.sh" "$WORK_DIR/pause-bin" "$WORK_DIR/idle-bin"

# The kubelet's sandboxes ask for oom_score_adj -998. A host without CAP_SYS_RESOURCE (some sandboxes) cannot grant it and runc 1.1.5 then fails with
# "can't get final child's PID from pipe": there, and only there, a runc wrapper drops the negative value (it is first in the PATH of containerd and dockerd).
SHIM_DIR="$LIB/shim"
if sudo sh -c 'echo -998 > /proc/self/oom_score_adj' 2>/dev/null; then
    echo "[setup] this host can lower oom_score_adj: no runc wrapper"
    SHIM_PATH=""
else
    echo "[setup] this host cannot lower oom_score_adj (no CAP_SYS_RESOURCE): a runc wrapper drops the negative oomScoreAdj of the sandboxes..."
    sudo install -d -m 755 "$SHIM_DIR"
    cat <<'SHEOF' | sudo tee "$SHIM_DIR/runc" >/dev/null
#!/bin/bash
real=/var/lib/bench53435138/opt/docker/runc
bundle=""; prev=""
for a in "$@"; do
    if [ "$prev" = "--bundle" ] || [ "$prev" = "-b" ]; then bundle="$a"; fi
    prev="$a"
done
if [ -n "$bundle" ] && [ -f "$bundle/config.json" ] && grep -q '"oomScoreAdj"' "$bundle/config.json"; then
    python3 - "$bundle/config.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
pr = c.get("process", {})
if pr.get("oomScoreAdj", 0) < 0:
    del pr["oomScoreAdj"]
    json.dump(c, open(p, "w"))
PY
fi
exec "$real" "$@"
SHEOF
    sudo chmod 755 "$SHIM_DIR/runc"
    SHIM_PATH="$SHIM_DIR:"
fi

echo "[setup] containerd of the node (its CRI plugin on, as in the default configuration of the release; the runtime of the kubelet, there is no Docker daemon on this node)..."
PATH="$D:$PATH" "$D/containerd" config default > "$WORK_DIR/containerd-default.toml"
python3 - "$WORK_DIR/containerd-default.toml" "$LIB" "$RUN" "$PAUSE_REF" > "$WORK_DIR/containerd.toml" <<'PYEOF'
import sys
p, lib, run, pause = sys.argv[1:5]
s = open(p).read()
for old, new in (('root = "/var/lib/containerd"', 'root = "%s/containerd"' % lib), ('state = "/run/containerd"', 'state = "%s/containerd"' % run),
                 ('address = "/run/containerd/containerd.sock"', 'address = "%s/containerd.sock"' % run),
                 ('sandbox_image = "registry.k8s.io/pause:3.6"', 'sandbox_image = "%s"' % pause),
                 ('bin_dir = "/opt/cni/bin"', 'bin_dir = "%s/cni/bin"' % lib), ('conf_dir = "/etc/cni/net.d"', 'conf_dir = "%s/cni/net.d"' % lib),
                 ('Root = ""', 'Root = "%s/runc"' % run)):
    if old not in s:
        sys.exit("the default configuration of this containerd has no line: " + old)
    s = s.replace(old, new)
if 'disabled_plugins = []' not in s:
    sys.exit("the default configuration disables a plugin")
sys.stdout.write(s)
PYEOF
sudo install -m 644 "$WORK_DIR/containerd.toml" "$LIB/etc/containerd.toml"
rm -f "$WORK_DIR/containerd.toml" "$WORK_DIR/containerd-default.toml"
sudo sh -c "PATH='$SHIM_PATH$D:$PATH' setsid sh -c 'echo \$\$ > \"\$1\"; exec \"\$2\" --config \"\$3\"' sh '$RUN/containerd.pid' '$D/containerd' '$LIB/etc/containerd.toml' >>'$RUN/containerd.log' 2>&1 </dev/null &"
for _ in $(seq 60); do [ -S "$RUN/containerd.sock" ] && sudo "$D/ctr" -a "$RUN/containerd.sock" version >/dev/null 2>&1 && break; sleep 0.5; done
sudo "$D/ctr" -a "$RUN/containerd.sock" version >/dev/null 2>&1 || { echo "[setup] ERROR: containerd did not start"; sudo tail -8 "$RUN/containerd.log"; exit 1; }

echo "[setup] the three images are imported into the namespace k8s.io of containerd (the kubelet never pulls: imagePullPolicy Never)..."
for t in pause agent dind; do
    sudo "$D/ctr" -a "$RUN/containerd.sock" -n k8s.io images import "$STATE_DIR/$t.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: containerd could not import the $t image"; exit 1; }
done

echo "[setup] the kubelet: KubeletConfiguration, the flags of kubeadm for a containerd node, kubeletctl (start|stop|restart|status), the Jenkins workspace and the static pod jenkins..."
cat <<CEOF | sudo tee "$LIB/kubelet/config.yaml" >/dev/null
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: cgroupfs
cgroupsPerQOS: false
enforceNodeAllocatable: []
failSwapOn: false
staticPodPath: $LIB/kubelet/manifests
authentication: {anonymous: {enabled: false}, webhook: {enabled: false}}
authorization: {mode: AlwaysAllow}
address: 127.0.0.1
port: 17253
healthzPort: 0
readOnlyPort: 0
makeIPTablesUtilChains: false
syncFrequency: 5s
fileCheckFrequency: 5s
imageGCHighThresholdPercent: 100
imageGCLowThresholdPercent: 99
evictionHard: {memory.available: "1Mi", nodefs.available: "1%", imagefs.available: "1%", nodefs.inodesFree: "1%"}
CEOF
cat <<CEOF | sudo tee "$LIB/kubelet/kubeadm-flags.env" >/dev/null
KUBELET_KUBEADM_ARGS="--hostname-override=$CASE_ID --root-dir=$LIB/kubelet/root --cert-dir=$LIB/kubelet/pki --container-runtime=remote --container-runtime-endpoint=unix://$RUN/containerd.sock"
CEOF
cat <<CEOF | sudo tee "$LIB/kubelet/kubelet-extra.env" >/dev/null
# extra arguments of the kubelet (the file /etc/default/kubelet of the packages)
KUBELET_EXTRA_ARGS=""
CEOF
cat <<'CEOF' | sudo tee "$LIB/bin/kubeletctl" >/dev/null
#!/bin/bash
# kubeletctl start|stop|restart|status : the kubelet of this node, started the way the unit of the kubelet package does it: the configuration file plus the
# arguments of kubelet/kubeadm-flags.env (KUBELET_KUBEADM_ARGS) and kubelet/kubelet-extra.env (KUBELET_EXTRA_ARGS). Must run as root.
L=/var/lib/bench53435138
R=/run/bench53435138
PIDF="$R/kubelet.pid"
[ "$(id -u)" = 0 ] || { echo "kubeletctl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "$PIDF" ] && cat "$PIDF"; }
running() { local p; p=$(pid) && [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = kubelet ]; }
start() {
    if running; then echo "kubeletctl: the kubelet is already running (pid $(pid))"; return 0; fi
    mkdir -p "$R"
    setsid -f bash -c '
        echo $$ > "$1/kubelet.pid"
        . "$2/kubeadm-flags.env"
        . "$2/kubelet-extra.env"
        exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin '"$L"'/opt/kubelet --config "$2/config.yaml" $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
    ' _ "$R" "$L/kubelet" >> "$R/kubelet.log" 2>&1 < /dev/null
    for _ in $(seq 20); do running && { echo "kubeletctl: the kubelet started (pid $(pid))"; return 0; }; sleep 0.5; done
    echo "kubeletctl: the kubelet did not start; see $R/kubelet.log" >&2; return 1
}
stop() {
    local p; p=$(pid) || true
    if [ -n "$p" ] && running; then
        kill -TERM "$p" 2>/dev/null
        for _ in $(seq 40); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
        kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    fi
    rm -f "$PIDF"; echo "kubeletctl: the kubelet stopped"
}
case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) if running; then echo "the kubelet is running (pid $(pid))"; else echo "the kubelet is not running"; exit 1; fi ;;
    *) echo "usage: kubeletctl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
sudo chmod 755 "$LIB/bin/kubeletctl"
sudo install -d -m 755 "$LIB/workspace"
# the Jenkins pod as the question has it: the socket of containerd is mounted as /var/run/docker.sock; the workspace of the job is the other volume
cat <<CEOF | sudo tee "$LIB/kubelet/manifests/jenkins.yaml" >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: jenkins
  namespace: ci
spec:
  hostNetwork: true
  containers:
  - name: agent
    image: $AGENT_REF
    imagePullPolicy: Never
    volumeMounts:
    - name: docker-sock
      mountPath: /var/run/docker.sock
    - name: workspace
      mountPath: /home/jenkins/agent
  volumes:
  - name: docker-sock
    hostPath:
      path: $SOCK_SRC
      type: Socket
  - name: workspace
    hostPath:
      path: $LIB/workspace
      type: Directory
CEOF
sudo "$LIB/bin/kubeletctl" start >/dev/null || { echo "[setup] ERROR: the kubelet did not start"; sudo tail -8 "$RUN/kubelet.log"; exit 1; }

echo "[setup] waiting for the kubelet to start the pod jenkins..."
cri() { sudo crictl -r "unix://$RUN/containerd.sock" -i "unix://$RUN/containerd.sock" --timeout 60s "$@"; }
for _ in $(seq 90); do cri ps 2>/dev/null | grep -q " agent " && break; sleep 1; done
cri ps 2>/dev/null | grep -q " agent " || { echo "[setup] ERROR: the kubelet did not start the pod jenkins"; sudo tail -12 "$RUN/kubelet.log" | cut -c1-300; exit 1; }

echo "[setup] the record of what is true..."
cri images -o json | sudo tee "$STATE_DIR/images.json" >/dev/null
sudo python3 - "$LIB" "$RUN" "$STATE_DIR" "$CASE_ID" <<'PYEOF'
import hashlib, json, os, sys
lib, run, state, case = sys.argv[1:5]
def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()
def start(pid):
    return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
t = {"kubelet_sha": sha(lib + "/opt/kubelet"), "containerd_sha": sha(lib + "/opt/docker/containerd"), "runc_sha": sha(lib + "/opt/docker/runc"),
     "kctl_sha": sha(lib + "/bin/kubeletctl"), "job_sha": sha(state + "/job")}
for n in ("containerd", "kubelet"):
    t[n + "_start"] = start(int(open("%s/%s.pid" % (run, n)).read()))
ids = {}
for img in json.load(open(state + "/images.json"))["images"]:
    for tag in img.get("repoTags", []):
        if tag.startswith(case + ".local/"):
            ids[tag] = img["id"]
t["images"] = ids
json.dump(t, open(state + "/truth.json", "w"))
PYEOF

echo "[setup] done. The pod jenkins (agent) mounts containerd's socket as /var/run/docker.sock; the images agent and dind are in the node."
