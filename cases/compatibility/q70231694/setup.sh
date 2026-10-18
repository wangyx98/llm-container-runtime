#!/bin/bash
set -e

CASE_ID="bench70231694"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files and logs of containerd, k3s and BuildKit
LIB_BASE="/var/lib/$CASE_ID"          # roots of containerd, of k3s, its kubelet and BuildKit, the programs, the Pod's manifest, the build context
CTL_DIR="$LIB_BASE/bin"               # control scripts (not in /run: it is mounted noexec on many hosts)
LIBEXEC="$LIB_BASE/libexec"           # k3s, buildkitd and buildctl of this machine
BK_DIR="$LIB_BASE/buildkit"           # buildkitd.toml and BuildKit's root
BK_SOCK="$RUN_BASE/buildkit/buildkitd.sock"
WORKSPACE="$LIB_BASE/workspace"       # the engineer's build context: Dockerfile and payload.bin
CACHE="/var/cache/$CASE_ID"           # the downloaded and checked k3s, nerdctl and BuildKit (kept by cleanup.sh)
CTD_SOCK="$RUN_BASE/containerd.sock"
NODE="bench70231694-node"
POD="builder"
POD_IMAGE="bench70231694.local/builder:1"
BASE_IMAGE="localhost/bench70231694-base:1"  # the base image of the Dockerfile, built here and imported into containerd's namespace default
PAUSE_REF="bench70231694.local/pause:1"      # sandbox ("pause") image, built here: no download at run time
BREW_BIN="/home/linuxbrew/.linuxbrew/bin"    # where the engineer's Pod has nerdctl (brew install nerdctl)
CNI_CRI="$LIB_BASE/cni-cri"                  # stub plugins for the pod sandboxes of the kubelet

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

K3S_VERSION="v1.30.5+k3s1"
NERDCTL_VERSION="2.1.3"
BUILDKIT_VERSION="v0.23.2"
# release asset and sha256 per architecture (sha256sum-<arch>.txt of the k3s release, SHA256SUMS of the nerdctl release, sha256 of the BuildKit release asset)
case "$(uname -m)" in
    x86_64)        K3S_ASSET="k3s";       K3S_SHA256="322fbdc904deb1bf2f7a4460c0ae616db3aea75b8aefe911286946cdb0893d95"
                   NERDCTL_ASSET="nerdctl-$NERDCTL_VERSION-linux-amd64.tar.gz"; NERDCTL_SHA256="227390fb16c20d6ab3a7588e5ce72202df1bec7960a2a091599ce3c1bf3fd1d8"
                   BK_ASSET="buildkit-$BUILDKIT_VERSION.linux-amd64.tar.gz";    BK_SHA256="2771c3403e3a1f75a83cde387a05365794d3b900c355e864772a36c3ce541f82" ;;
    aarch64|arm64) K3S_ASSET="k3s-arm64"; K3S_SHA256="da3b23dc736401259f2e5ada5c481f8302d4f8a55b6d580e1abecaf85e89f2ac"
                   NERDCTL_ASSET="nerdctl-$NERDCTL_VERSION-linux-arm64.tar.gz"; NERDCTL_SHA256="62e34ce6156c942368968c0d88c731cb2f3b341785d584e56a2c175916d5f88d"
                   BK_ASSET="buildkit-$BUILDKIT_VERSION.linux-arm64.tar.gz";    BK_SHA256="6385ff70b2fb4134b50ac3183eea3a0b06c6f6129173940d73178ae0477368f1" ;;
    *)             K3S_ASSET=""; K3S_SHA256=""; NERDCTL_ASSET=""; NERDCTL_SHA256=""; BK_ASSET=""; BK_SHA256="" ;;
esac
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
OWNED_MARKER="$LIB_BASE/host_dirs_owned"     # k3s' fixed directories are the case's own once this exists

CTR="sudo ctr -a $CTD_SOCK"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking containerd, ctr, runc, curl, tar and python3 are installed (the runtime under test; same"
echo "[setup] assumption as the other containerd cases)..."
for b in containerd ctr runc curl tar python3 sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
[ -n "$K3S_ASSET" ] || { echo "[setup] ERROR: no k3s/nerdctl/BuildKit is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking this host has no k3s or kubelet state of its own (they keep files in fixed places that this case"
echo "[setup] manages)..."
for d in /etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s; do
    [ ! -e "$d" ] || { echo "[setup] ERROR: $d exists: this host has its own k3s or kubelet state, the case would damage it"; exit 1; }
done
for c in k3s-server k3s-agent kubelet; do
    ! pgrep -x "$c" >/dev/null 2>&1 || { echo "[setup] ERROR: a $c process runs on this host: the case needs a host without k3s or a kubelet"; exit 1; }
done

echo "[setup] making sure gcc is available (gcc: one tiny static program, the entry point of the Pod and the sandbox image,"
echo "[setup] so nothing has to be pulled)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$RUN_BASE/buildkit" "$LIB_BASE/containerd" "$CTL_DIR" "$LIBEXEC" "$BK_DIR/root" "$WORKSPACE" "$CNI_CRI/bin" "$CNI_CRI/net.d"
# the network namespaces that are there, and the log directories of the kubelet, which other k3s or kubelet cases may use too: what is there now
# stays, cleanup.sh removes only what the case's kubelet adds
ls /run/netns 2>/dev/null | sudo tee "$LIB_BASE/netns.before" >/dev/null || true
for d in pods containers; do ls -A "/var/log/$d" 2>/dev/null | sudo tee "$LIB_BASE/logs.$d.before" >/dev/null || true; done
sudo touch "$OWNED_MARKER"      # from here on cleanup.sh may remove the fixed directories
cd "$WORK_DIR"

echo "[setup] k3s $K3S_VERSION, nerdctl $NERDCTL_VERSION and BuildKit $BUILDKIT_VERSION: from the cache $CACHE, else downloaded;"
echo "[setup] the sha256 is checked either way..."
sudo mkdir -p "$CACHE"
fetch() {   # $1 = cache file, $2 = sha256, $3 = URL, $4 = local copy from the environment (may be empty)
    if sudo test -f "$1" && echo "$2  $1" | sudo sha256sum -c - >/dev/null 2>&1; then return 0; fi
    local tmp="$STATE_DIR/download"
    if [ -n "$4" ]; then cp "$4" "$tmp"
    else curl -fsSL --retry 3 --max-time 600 -o "$tmp" "$3" || { echo "[setup] ERROR: could not download $3"; exit 1; }
    fi
    echo "$2  $tmp" | sha256sum -c - >/dev/null 2>&1 || { rm -f "$tmp"; echo "[setup] ERROR: $3 has the wrong sha256"; exit 1; }
    sudo install -m 644 "$tmp" "$1"
    rm -f "$tmp"
}
fetch "$CACHE/$K3S_ASSET-$K3S_VERSION" "$K3S_SHA256" "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/$K3S_ASSET" "${BENCH70231694_K3S_BIN:-}"
fetch "$CACHE/$NERDCTL_ASSET" "$NERDCTL_SHA256" "https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_VERSION/$NERDCTL_ASSET" "${BENCH70231694_NERDCTL_TGZ:-}"
fetch "$CACHE/$BK_ASSET" "$BK_SHA256" "https://github.com/moby/buildkit/releases/download/$BUILDKIT_VERSION/$BK_ASSET" "${BENCH70231694_BUILDKIT_TGZ:-}"
sudo install -m 755 "$CACHE/$K3S_ASSET-$K3S_VERSION" "$LIBEXEC/k3s"
K3S_BIN="$LIBEXEC/k3s"
sudo tar -xzf "$CACHE/$NERDCTL_ASSET" -C "$STATE_DIR" nerdctl      # goes into the Pod image only: the machine has no nerdctl of its own
sudo tar -xzf "$CACHE/$BK_ASSET" -C "$STATE_DIR" bin/buildkitd bin/buildctl
sudo install -m 755 "$STATE_DIR/bin/buildkitd" "$STATE_DIR/bin/buildctl" "$LIBEXEC/"
"$K3S_BIN" --version | head -1
"$LIBEXEC/buildkitd" --version
"$LIBEXEC/buildctl" --version

echo "[setup] building the three images offline: the base image of the Dockerfile (a small shell toolset taken from this machine),"
echo "[setup] the sandbox image of the pods (a static program that only waits) and the image of the engineer's Pod (nerdctl at"
echo "[setup] $BREW_BIN, the same kind of toolset with tar, an idle entry point)..."
cat > "$STATE_DIR/idle.c" <<'CEOF'
#include <signal.h>
#include <unistd.h>

static void bye(int sig) { _exit(0); }

int main(void) {
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    for (;;) pause();
}
CEOF
gcc -static -Os -s -w -o "$STATE_DIR/idle" "$STATE_DIR/idle.c"
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
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
DEFPATH="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
mkdir -p "$STATE_DIR/pause-root"
cp "$STATE_DIR/idle" "$STATE_DIR/pause-root/pause"
add_tool() {    # $1 = root of the image, $2 = a program of this machine; it is copied with the libraries it needs (ldd)
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
skeleton() {    # $1 = root of an image
    mkdir -p "$1/usr/bin" "$1/usr/local/bin" "$1/tmp" "$1/etc" "$1/proc" "$1/sys" "$1/dev" "$1/run" "$1/var"
    chmod 1777 "$1/tmp"
    ln -s usr/bin "$1/bin"
    ln -s ../run "$1/var/run"
}
BASEROOT="$STATE_DIR/base-root"
skeleton "$BASEROOT"
for t in sh cat ls sha256sum; do add_tool "$BASEROOT" "$t"; done
PODROOT="$STATE_DIR/pod-root"
skeleton "$PODROOT"
mkdir -p "$PODROOT$BREW_BIN"
cp "$STATE_DIR/nerdctl" "$PODROOT$BREW_BIN/nerdctl"
cp "$STATE_DIR/idle" "$PODROOT/usr/local/bin/idle"
for t in sh ls cat mkdir grep sleep id ps head tail stat readlink sha256sum env cp ln rm touch find tar chmod; do add_tool "$PODROOT" "$t"; done
python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/base.tar" "$BASE_IMAGE" "$BASEROOT" "$DEFPATH" /bin/sh
python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause.tar" "$PAUSE_REF" "$STATE_DIR/pause-root" "$DEFPATH" /pause
python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pod.tar" "$POD_IMAGE" "$PODROOT" "PATH=$BREW_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" /usr/local/bin/idle

echo "[setup] starting the pre-installed containerd (the runtime of this machine: own socket, root and state; containerd's"
echo "[setup] own default config for the installed version, moved into that root/state, NRI off, stub network plugins for the"
echo "[setup] pod sandboxes of the kubelet, and the sandbox image of the pods)..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock, cni, pause = sys.argv[1:6]
section = ""
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}'\n"
    elif (section == "grpc" or section.endswith("server.v1.grpc")) and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif (section == "ttrpc" or section.endswith("server.v1.ttrpc")) and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        # do not require CAP_SYS_RESOURCE (absent in unprivileged or nested environments)
        line = f"{indent}restrict_oom_score_adj = true\n"
    elif section.endswith(".cni") and k == "bin_dirs":
        line = f"{indent}bin_dirs = ['{cni}/bin']\n"
    elif section.endswith(".cni") and k == "bin_dir" and not re.search(r"=\s*(''|\"\")\s*$", line):
        # containerd 1.x: bin_dir; 2.x has bin_dirs (and an empty bin_dir, which must stay empty)
        line = f"{indent}bin_dir = '{cni}/bin'\n"
    elif section.endswith(".cni") and k == "conf_dir":
        line = f"{indent}conf_dir = '{cni}/net.d'\n"
    elif "pinned_images" in section and k == "sandbox":
        line = f"{indent}sandbox = '{pause}'\n"
    elif k == "sandbox_image":
        line = f"{indent}sandbox_image = '{pause}'\n"
    sys.stdout.write(line)
PYEOF
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" "$CNI_CRI" "$PAUSE_REF" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
grep -q "$PAUSE_REF" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
grep -q "$CTD_SOCK" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the socket in the containerd config"; exit 1; }
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
$CTR -n k8s.io images import "$STATE_DIR/pod.tar" >/dev/null 2>&1 \
    || { echo "[setup] ERROR: ctr could not import the image of the Pod"; exit 1; }
$CTR -n default images import "$STATE_DIR/base.tar" >/dev/null 2>&1 \
    || { echo "[setup] ERROR: ctr could not import the base image"; exit 1; }

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

echo "[setup] BuildKit $BUILDKIT_VERSION of this machine: buildkitd with a containerd worker on the containerd of this machine (config"
echo "[setup] $BK_DIR/buildkitd.toml, socket $BK_SOCK), started and stopped with buildkitctl..."
cat <<CEOF | sudo tee "$BK_DIR/buildkitd.toml" >/dev/null
# configuration of the BuildKit of this machine
root = "$BK_DIR/root"

[grpc]
  address = ["unix://$BK_SOCK"]

[worker.oci]
  enabled = false

[worker.containerd]
  enabled = true
  address = "$CTD_SOCK"
  namespace = "buildkit"
CEOF
cat <<CEOF | sudo tee "$CTL_DIR/buildkitctl" >/dev/null
#!/bin/bash
# how BuildKit is started and stopped on this machine: buildkitctl start|stop|restart|status
# (buildkitd reads its options from $BK_DIR/buildkitd.toml)
PIDF="$RUN_BASE/buildkitd.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "buildkitd is already running"; return 0; fi
    mkdir -p "$RUN_BASE/buildkit"
    setsid -f bash -c 'echo \$\$ > "\$1"; exec "\$2" --config "\$3" >>"\$4" 2>&1 </dev/null' _ "\$PIDF" "$LIBEXEC/buildkitd" "$BK_DIR/buildkitd.toml" "$RUN_BASE/buildkitd.log" </dev/null >/dev/null 2>&1
    echo "buildkitd started"
}
do_stop() {
    alive || { echo "buildkitd is not running"; return 0; }
    kill -TERM "\$(cat "\$PIDF")"
    for _ in \$(seq 1 40); do alive || break; sleep 0.5; done
    alive && kill -KILL "\$(cat "\$PIDF")"
    echo "buildkitd stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid \$(cat "\$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: buildkitctl start|stop|restart|status"; exit 2 ;;
esac
CEOF
sudo chmod 755 "$CTL_DIR/buildkitctl"
sudo "$CTL_DIR/buildkitctl" start >/dev/null
for _ in $(seq 1 60); do
    [ -S "$BK_SOCK" ] && sudo "$LIBEXEC/buildctl" --addr "unix://$BK_SOCK" debug workers >/dev/null 2>&1 && break
    sleep 0.5
done
if ! sudo "$LIBEXEC/buildctl" --addr "unix://$BK_SOCK" debug workers >/dev/null 2>&1; then
    echo "[setup] ERROR: buildkitd did not come up; last log lines:"
    sudo tail -10 "$RUN_BASE/buildkitd.log" 2>/dev/null | cut -c1-200 || true
    exit 1
fi
echo "  -> buildkitd up on $BK_SOCK"

echo "[setup] the engineer's build context $WORKSPACE: a Dockerfile and payload.bin (1 MiB of random bytes)..."
cat <<CEOF | sudo tee "$WORKSPACE/Dockerfile" >/dev/null
FROM $BASE_IMAGE
COPY payload.bin /payload.bin
RUN sha256sum /payload.bin > /payload.sha256
CEOF
sudo sh -c 'head -c 1048576 /dev/urandom > "$1/payload.bin"' _ "$WORKSPACE"
sudo chmod 755 "$WORKSPACE"
sudo chmod 644 "$WORKSPACE/Dockerfile" "$WORKSPACE/payload.bin"
sudo sha256sum "$WORKSPACE/payload.bin" | awk '{print $1}' > "$STATE_DIR/payload.sha"

echo "[setup] the engineer's Pod $POD ($LIB_BASE/$POD.yaml): not privileged, root, the build context and the containerd socket of"
echo "[setup] this node mounted, nerdctl $NERDCTL_VERSION installed at $BREW_BIN/nerdctl..."
cat <<CEOF | sudo tee "$LIB_BASE/$POD.yaml" >/dev/null
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: $POD
  name: $POD
spec:
  containers:
    - name: nerdctl
      image: $POD_IMAGE
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: false
        runAsUser: 0
      volumeMounts:
        - mountPath: /workspace
          name: workspace
          readOnly: true
        - mountPath: /run/containerd/containerd.sock
          name: containerd
  restartPolicy: Always
  volumes:
    - name: workspace
      hostPath:
        path: $WORKSPACE
    - name: containerd
      hostPath:
        path: $CTD_SOCK
CEOF
for _ in $(seq 1 30); do
    $KC get serviceaccount default >/dev/null 2>&1 && break
    sleep 1
done
$KC apply -f "$LIB_BASE/$POD.yaml" >/dev/null || { echo "[setup] ERROR: could not create the Pod"; exit 1; }
PREADY=""
for _ in $(seq 1 90); do
    PREADY=$($KC get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
    [ "$PREADY" = "true" ] && break
    sleep 2
done
if [ "$PREADY" != "true" ]; then
    echo "[setup] ERROR: the Pod $POD is not ready"; $KC get pods -A 2>&1 | head; $KC describe pod "$POD" 2>&1 | tail -15; exit 1
fi
echo "  -> Pod $POD running"

echo "[setup] recording what is true now (identity of the daemons, hashes of the files the case does not let anyone change,"
echo "[setup] the containers and images of the node)..."
for d in containerd k3s buildkitd; do
    P=$(cat "$RUN_BASE/$d.pid")
    echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/$d.id"
done
sudo sh -c 'cd /; sha256sum "$@" | awk "{print \$1}"' _ \
    "$RUN_BASE/config.toml" "$K3S_CONFIG" "$CTL_DIR/kubectl" "$CTL_DIR/containerdctl" "$CTL_DIR/k3sctl" "$CTL_DIR/buildkitctl" \
    "$LIBEXEC/buildkitd" "$LIBEXEC/buildctl" "$LIBEXEC/k3s" "$WORKSPACE/Dockerfile" "$WORKSPACE/payload.bin" > "$STATE_DIR/files.sha"
sha256sum "$STATE_DIR/nerdctl" | awk '{print $1}' > "$STATE_DIR/nerdctl.sha"
sudo sha256sum "$BK_DIR/buildkitd.toml" | awk '{print $1}' > "$STATE_DIR/toml.sha"
sudo cp "$LIBEXEC/buildctl" "$STATE_DIR/buildctl"       # the oracle's own copy: it does not trust the one the solution may have touched
$KC get pod "$POD" -o jsonpath='{.metadata.uid}' > "$STATE_DIR/pod.uid"
$KC get pod "$POD" -o jsonpath='{.spec.containers[0].image}' > "$STATE_DIR/pod.image"
$CTR -n default containers ls -q 2>/dev/null | sort > "$STATE_DIR/containers.0"
$CTR -n default images ls -q 2>/dev/null | sort > "$STATE_DIR/images.0"
sudo chmod 755 "$STATE_DIR"
sudo chmod 600 "$STATE_DIR"/*.id "$STATE_DIR"/files.sha "$STATE_DIR"/nerdctl.sha "$STATE_DIR"/toml.sha "$STATE_DIR"/payload.sha "$STATE_DIR"/pod.uid "$STATE_DIR"/pod.image "$STATE_DIR"/containers.0 "$STATE_DIR"/images.0 2>/dev/null || true
sudo chmod 700 "$STATE_DIR/buildctl"

echo "[setup] removing the build inputs..."
sudo rm -rf "$STATE_DIR/idle" "$STATE_DIR/idle.c" "$STATE_DIR/mkimg.py" "$STATE_DIR/patch_config.py" "$STATE_DIR"/*.tar "$STATE_DIR/bin" \
    "$STATE_DIR/base-root" "$STATE_DIR/pause-root" "$STATE_DIR/pod-root" "$STATE_DIR/nerdctl"

echo "[setup] done. In the Pod $POD, nerdctl ps and nerdctl images work, nerdctl build does not."
