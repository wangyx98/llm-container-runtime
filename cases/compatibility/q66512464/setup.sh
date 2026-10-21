#!/bin/bash
set -e

CASE_ID="bench66512464"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                          # the node: Docker and containerd (programs, data), the kubelet (program, configuration, manifests, root dir), kubeletctl
RUN="/run/$CASE_ID"                              # sockets, pid files and logs of the daemons
CACHE="/var/cache/$CASE_ID"                      # the downloaded and checked kubelet and Docker packages (kept by cleanup.sh)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): truth.json, the images
K8S_VERSION="v1.23.17"                           # the last Kubernetes 1.23: dockershim is still in the kubelet (it was removed in 1.24)
DOCKER_VERSION="20.10.24"                        # a Docker of the same years; its static package brings dockerd, containerd 1.6.20 and runc 1.1.5
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
APP_REF="$CASE_ID.local/web:1"

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

echo "[setup] the programs of the workload (static, so nothing is pulled from a public registry) and the two images as classic docker archives..."
cat > "$WORK_DIR/web.c" <<'CEOF'
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
cat > "$WORK_DIR/mkdocker.py" <<'PYEOF'
"""mkdocker.py OUT REF BINARY ENTRY : a one-layer image as a classic `docker save` archive (manifest.json), loadable by docker load and ctr images import"""
import hashlib, io, json, os, sys, tarfile
out, ref, binary, entry = sys.argv[1:5]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
def ti(name, size, mode=0o644):
    t = tarfile.TarInfo(name); t.size = size; t.mode = mode; t.mtime = 1700000000; t.uid = t.gid = 0; return t
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    d = open(binary, "rb").read(); t.addfile(ti(entry, len(d), 0o755), io.BytesIO(d))
layer = buf.getvalue()
diff = "sha256:" + hashlib.sha256(layer).hexdigest()
cfg = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
    "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], "Entrypoint": ["/" + entry], "Cmd": [], "WorkingDir": "/"},
    "rootfs": {"type": "layers", "diff_ids": [diff]}, "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY %s /" % entry}]}, separators=(",", ":")).encode()
cname = hashlib.sha256(cfg).hexdigest() + ".json"
lname = hashlib.sha256(layer).hexdigest() + "/layer.tar"
man = json.dumps([{"Config": cname, "RepoTags": [ref], "Layers": [lname]}]).encode()
with tarfile.open(out, "w") as t:
    for n, data in ((cname, cfg), (lname, layer), ("manifest.json", man)):
        t.addfile(ti(n, len(data)), io.BytesIO(data))
print(json.dumps({"id": "sha256:" + cname[:-5], "diff": diff}))
PYEOF
gcc -static -Os -s -w -o "$WORK_DIR/web-bin" "$WORK_DIR/web.c"
gcc -static -Os -s -w -o "$WORK_DIR/pause-bin" "$WORK_DIR/pause.c"
python3 "$WORK_DIR/mkdocker.py" "$WORK_DIR/web.tar" "$APP_REF" "$WORK_DIR/web-bin" web >/dev/null
python3 "$WORK_DIR/mkdocker.py" "$WORK_DIR/pause.tar" "$PAUSE_REF" "$WORK_DIR/pause-bin" pause >/dev/null
sudo mv "$WORK_DIR/web.tar" "$WORK_DIR/pause.tar" "$STATE_DIR/"
rm -f "$WORK_DIR/web.c" "$WORK_DIR/pause.c" "$WORK_DIR/mkdocker.py" "$WORK_DIR/web-bin" "$WORK_DIR/pause-bin"

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
real=/var/lib/bench66512464/opt/docker/runc
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

echo "[setup] containerd (its CRI plugin on, as in the default configuration of the release) and, on top of it, dockerd (Docker keeps its containers in the namespace $CASE_ID-docker, the kubelet's CRI uses k8s.io)..."
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
cat <<CEOF | sudo tee "$LIB/etc/daemon.json" >/dev/null
{
  "data-root": "$LIB/docker",
  "exec-root": "$RUN/docker-exec",
  "containerd": "$RUN/containerd.sock",
  "containerd-namespace": "$CASE_ID-docker",
  "containerd-plugins-namespace": "$CASE_ID-plugins",
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "bridge": "none",
  "iptables": false,
  "ip6tables": false,
  "ip-forward": false,
  "userland-proxy": false
}
CEOF
sudo sh -c "PATH='$SHIM_PATH$D:$PATH' setsid sh -c 'echo \$\$ > \"\$1\"; exec \"\$2\" --config \"\$3\"' sh '$RUN/containerd.pid' '$D/containerd' '$LIB/etc/containerd.toml' >>'$RUN/containerd.log' 2>&1 </dev/null &"
for _ in $(seq 60); do [ -S "$RUN/containerd.sock" ] && sudo "$D/ctr" -a "$RUN/containerd.sock" version >/dev/null 2>&1 && break; sleep 0.5; done
sudo "$D/ctr" -a "$RUN/containerd.sock" version >/dev/null 2>&1 || { echo "[setup] ERROR: containerd did not start"; sudo tail -8 "$RUN/containerd.log"; exit 1; }
sudo sh -c "PATH='$SHIM_PATH$D:$PATH' setsid sh -c 'echo \$\$ > \"\$1\"; exec \"\$2\" --config-file \"\$3\" --host unix://\$4' sh '$RUN/dockerd.pid' '$D/dockerd' '$LIB/etc/daemon.json' '$RUN/docker.sock' >>'$RUN/dockerd.log' 2>&1 </dev/null &"
for _ in $(seq 90); do sudo "$D/docker" -H "unix://$RUN/docker.sock" version >/dev/null 2>&1 && break; sleep 0.5; done
sudo "$D/docker" -H "unix://$RUN/docker.sock" version >/dev/null 2>&1 || { echo "[setup] ERROR: dockerd did not start"; sudo tail -8 "$RUN/dockerd.log"; exit 1; }

echo "[setup] both images are loaded into Docker and into the namespace k8s.io of containerd (the kubelet never pulls: imagePullPolicy Never)..."
for t in pause web; do
    sudo "$D/docker" -H "unix://$RUN/docker.sock" load -i "$STATE_DIR/$t.tar" >/dev/null || { echo "[setup] ERROR: docker could not load the $t image"; exit 1; }
    sudo "$D/ctr" -a "$RUN/containerd.sock" -n k8s.io images import "$STATE_DIR/$t.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: containerd could not import the $t image"; exit 1; }
done

echo "[setup] the kubelet: KubeletConfiguration, the flags kubeadm wrote for a Docker node, kubeletctl (start|stop|restart|status), the static pod web..."
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
port: 17250
healthzPort: 0
readOnlyPort: 0
makeIPTablesUtilChains: false
syncFrequency: 5s
fileCheckFrequency: 5s
imageGCHighThresholdPercent: 100
imageGCLowThresholdPercent: 99
evictionHard: {memory.available: "1Mi", nodefs.available: "1%", imagefs.available: "1%", nodefs.inodesFree: "1%"}
CEOF
# written the way kubeadm writes /var/lib/kubelet/kubeadm-flags.env for a node where it found Docker: no --container-runtime (the kubelet's default of 1.23 is docker)
cat <<CEOF | sudo tee "$LIB/kubelet/kubeadm-flags.env" >/dev/null
KUBELET_KUBEADM_ARGS="--hostname-override=$CASE_ID --root-dir=$LIB/kubelet/root --cert-dir=$LIB/kubelet/pki --container-runtime-endpoint=unix://$RUN/dockershim.sock --docker-endpoint=unix://$RUN/docker.sock --pod-infra-container-image=$PAUSE_REF"
CEOF
cat <<CEOF | sudo tee "$LIB/kubelet/kubelet-extra.env" >/dev/null
# extra arguments of the kubelet (the file /etc/default/kubelet of the packages)
KUBELET_EXTRA_ARGS=""
CEOF
cat <<'CEOF' | sudo tee "$LIB/bin/kubeletctl" >/dev/null
#!/bin/bash
# kubeletctl start|stop|restart|status : the kubelet of this node, started the way the unit of the kubelet package does it: the configuration file plus the
# arguments of kubelet/kubeadm-flags.env (KUBELET_KUBEADM_ARGS) and kubelet/kubelet-extra.env (KUBELET_EXTRA_ARGS). Must run as root.
L=/var/lib/bench66512464
R=/run/bench66512464
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
WEB_NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(6))')
cat <<CEOF | sudo tee "$LIB/kubelet/manifests/web.yaml" >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: default
spec:
  hostNetwork: true
  containers:
  - name: web
    image: $APP_REF
    imagePullPolicy: Never
    args: ["$WEB_NONCE"]
CEOF
sudo "$LIB/bin/kubeletctl" start >/dev/null || { echo "[setup] ERROR: the kubelet did not start"; sudo tail -8 "$RUN/kubelet.log"; exit 1; }

echo "[setup] waiting for the kubelet to start the pod web through its runtime (Docker)..."
for _ in $(seq 90); do
    sudo "$D/docker" -H "unix://$RUN/docker.sock" ps --format '{{.Names}}' 2>/dev/null | grep -q "^k8s_web_web-$CASE_ID" && break
    sleep 1
done
sudo "$D/docker" -H "unix://$RUN/docker.sock" ps --format '{{.Names}}' | grep -q "^k8s_web_web-$CASE_ID" || { echo "[setup] ERROR: the kubelet did not start the pod web in Docker"; sudo tail -12 "$RUN/kubelet.log" | cut -c1-300; exit 1; }

echo "[setup] the record of what is true..."
sudo python3 - "$LIB" "$RUN" "$STATE_DIR" "$WEB_NONCE" <<'PYEOF'
import hashlib, json, os, sys
lib, run, state, nonce = sys.argv[1:5]
def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()
def start(pid):
    return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
t = {"kubelet_sha": sha(lib + "/opt/kubelet"), "dockerd_sha": sha(lib + "/opt/docker/dockerd"), "containerd_sha": sha(lib + "/opt/docker/containerd"),
     "runc_sha": sha(lib + "/opt/docker/runc"), "kctl_sha": sha(lib + "/bin/kubeletctl"), "web_nonce": nonce}
for n in ("dockerd", "containerd"):
    pid = int(open("%s/%s.pid" % (run, n)).read())
    t[n + "_start"] = start(pid)
json.dump(t, open(state + "/truth.json", "w"))
PYEOF

echo "[setup] done. The kubelet (kubeletctl) runs the pod web through Docker; containerd runs next to it and has nothing of the kubelet."
