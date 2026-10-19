#!/bin/bash
set -e

CASE_ID="bench77044676"
RUN_BASE="/run/$CASE_ID"              # socket, pid files and logs of containerd and k3s
LIB_BASE="/var/lib/$CASE_ID"          # roots of containerd, of k3s and of its kubelet, the registry configuration, the control scripts, the engineer's files
CTL_DIR="$LIB_BASE/bin"               # control scripts (not in /run: it is mounted noexec on many hosts)
DEMO_DIR="$LIB_BASE/demo"             # what the engineer has: flaskapp.tar (docker save) and the Deployment's YAML
CACHE="/var/cache/$CASE_ID"           # the downloaded and checked k3s (kept by cleanup.sh)
CTD_SOCK="$RUN_BASE/containerd.sock"
CERTS="$LIB_BASE/certs.d"             # containerd's registry configuration (config_path)
NODE="bench77044676-node"
DEPLOY="flask-proj-deployment"
IMAGE="docker.io/library/flaskapp:v1"
PAUSE_REF="bench77044676.local/pause:1"      # sandbox ("pause") image, built here: no download at run time
CNI_CRI="$LIB_BASE/cni-cri"                  # stub plugins for the pod sandboxes of the kubelet

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

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

echo "[setup] checking containerd, ctr, runc, curl, tar and python3 are installed (the runtime under test; same"
echo "[setup] assumption as the other containerd cases)..."
for b in containerd ctr runc curl tar python3 sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
[ -n "$K3S_ASSET" ] || { echo "[setup] ERROR: no k3s is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking this host has no k3s or kubelet state of its own (they keep files in fixed places that this case manages)..."
for d in /etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s; do
    [ ! -e "$d" ] || { echo "[setup] ERROR: $d exists: this host has its own k3s or kubelet state, the case would damage it"; exit 1; }
done
for c in k3s-server k3s-agent kubelet; do
    ! pgrep -x "$c" >/dev/null 2>&1 || { echo "[setup] ERROR: a $c process runs on this host: the case needs a host without k3s or a kubelet"; exit 1; }
done

echo "[setup] making sure gcc is available (gcc: two tiny static programs, the only files of the app and sandbox images,"
echo "[setup] so nothing has to be pulled)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR" "$LIB_BASE/libexec" "$CNI_CRI/bin" "$CNI_CRI/net.d" "$CERTS/docker.io" "$DEMO_DIR"
ls /run/netns 2>/dev/null | sudo tee "$LIB_BASE/netns.before" >/dev/null || true
# the kubelet writes the logs of the Pods and containers into these two directories of the host, which other k3s or kubelet cases may use too:
# what is there now stays, cleanup.sh removes only what the case's kubelet adds
for d in pods containers; do ls -A "/var/log/$d" 2>/dev/null | sudo tee "$LIB_BASE/logs.$d.before" >/dev/null || true; done
sudo touch "$OWNED_MARKER"      # from here on cleanup.sh may remove the fixed directories
cd "$WORK_DIR"

echo "[setup] k3s $K3S_VERSION: from the cache $CACHE, else downloaded; the sha256 is checked either way..."
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
fetch "$CACHE/$K3S_ASSET-$K3S_VERSION" "$K3S_SHA256" "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/$K3S_ASSET" "${BENCH77044676_K3S_BIN:-}"
sudo install -m 755 "$CACHE/$K3S_ASSET-$K3S_VERSION" "$LIB_BASE/libexec/k3s"
K3S_BIN="$LIB_BASE/libexec/k3s"
"$K3S_BIN" --version | head -1

echo "[setup] building the images offline in the format of 'docker save': the engineer's flaskapp:v1 (one static program that prints a"
echo "[setup] nonce, which is different at every setup, every 5 seconds and never exits) and the sandbox image of the pods (a static program that only waits)..."
NONCE="nonce-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
cat > "$STATE_DIR/app.c" <<CEOF
#include <stdio.h>
#include <unistd.h>

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    for (;;) {
        printf("bench77044676-flaskapp $NONCE port=5001\n");
        sleep(5);
    }
}
CEOF
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
gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
gcc -static -Os -s -w -o "$STATE_DIR/idle" "$STATE_DIR/idle.c"
cat > "$STATE_DIR/mkdocker.py" <<'PYEOF'
"""mkdocker.py OUT.tar REPOTAG PROGRAM PATH-IN-IMAGE : the output of 'docker save REPOTAG' for a one-layer image whose only file is PROGRAM, its entry point"""
import hashlib
import io
import json
import os
import sys
import tarfile

out, repotag, program, path = sys.argv[1:5]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    with open(program, "rb") as f:
        data = f.read()
    ti = tarfile.TarInfo(path.lstrip("/"))
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], "Entrypoint": [path], "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps([{"Config": sha(config) + ".json", "RepoTags": [repotag], "Layers": [sha(layer) + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for name, d in ((sha(config) + ".json", config), (sha(layer) + "/layer.tar", layer), ("manifest.json", manifest)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(d), 1700000000
        t.addfile(ti, io.BytesIO(d))
PYEOF
python3 "$STATE_DIR/mkdocker.py" "$STATE_DIR/flaskapp.tar" "flaskapp:v1" "$STATE_DIR/app" /app
sudo install -m 644 "$STATE_DIR/flaskapp.tar" "$DEMO_DIR/flaskapp.tar"     # the demo directory belongs to root
python3 "$STATE_DIR/mkdocker.py" "$STATE_DIR/pause.tar" "$PAUSE_REF" "$STATE_DIR/idle" /pause

echo "[setup] starting the pre-installed containerd (the runtime of this machine: own socket, root and state; containerd's"
echo "[setup] own default config for the installed version, moved into that root/state, NRI off, stub network plugins for the"
echo "[setup] pod sandboxes of the kubelet, the sandbox image of the pods, and a registry configuration in which docker.io"
echo "[setup] does not answer: this node cannot pull from outside)..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock, cni, pause, certs = sys.argv[1:7]
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
    elif section.endswith(".registry") and k == "config_path":
        # the registry settings of the CRI plugin (a 1.x section of the grpc CRI plugin, a 2.x section of the images plugin)
        line = f"{indent}config_path = '{certs}'\n"
    sys.stdout.write(line)
PYEOF
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" "$CNI_CRI" "$PAUSE_REF" "$CERTS" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
grep -q "$PAUSE_REF" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
grep -q "$CTD_SOCK" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the socket in the containerd config"; exit 1; }
grep -q "config_path = '$CERTS'" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the registry configuration path in the containerd config"; exit 1; }
# docker.io is answered by nothing: a pull from it fails at once, whatever the host's network is
printf 'server = "http://127.0.0.1:9"\n' | sudo tee "$CERTS/docker.io/hosts.toml" >/dev/null
# Two stub network plugins for the pod sandboxes (containerd's CRI always adds "loopback" in front of the configured one):
# they answer CNI like real plugins but set no interface up.
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
echo "[setup] of this machine: k3sctl, kubectl, ctr and crictl (both aimed at this containerd)..."
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
cat <<CEOF | sudo tee "$CTL_DIR/ctr" >/dev/null
#!/bin/bash
# ctr aimed at the containerd of this machine (its default namespace is "default", or CONTAINERD_NAMESPACE)
exec ctr --address "$CTD_SOCK" "\$@"
CEOF
cat <<CEOF | sudo tee "$CTL_DIR/crictl" >/dev/null
#!/bin/bash
# the CRI client of this machine's Kubernetes (the crictl of k3s), aimed at the CRI of this machine's containerd, as the kubelet sees it
exec "$K3S_BIN" crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" "\$@"
CEOF
sudo chmod 755 "$CTL_DIR/k3sctl" "$CTL_DIR/kubectl" "$CTL_DIR/ctr" "$CTL_DIR/crictl"

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

echo "[setup] what the engineer did: ctr images import flaskapp.tar (the namespace was not given: default), then the Deployment..."
$CTR images import "$DEMO_DIR/flaskapp.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import flaskapp.tar"; exit 1; }
$CTR images ls -q | grep -qx "$IMAGE" || { echo "[setup] ERROR: ctr images ls does not show $IMAGE"; exit 1; }
cat <<CEOF | sudo tee "$DEMO_DIR/deployment.yaml" >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY
  namespace: default
  labels:
    app: flask-proj
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flask-proj
  template:
    metadata:
      labels:
        app: flask-proj
    spec:
      containers:
      - name: flask-proj
        image: $IMAGE
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 5001
CEOF
for _ in $(seq 1 30); do
    $KC get serviceaccount default >/dev/null 2>&1 && break
    sleep 1
done
$KC apply -f "$DEMO_DIR/deployment.yaml" >/dev/null || { echo "[setup] ERROR: could not create the Deployment"; exit 1; }
echo "[setup] waiting for the Pod of the Deployment to fail to pull (ErrImagePull / ImagePullBackOff)..."
WAITING=""
for _ in $(seq 1 90); do
    WAITING=$($KC get pods -l app=flask-proj -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
    case "$WAITING" in ErrImagePull|ImagePullBackOff) break ;; esac
    sleep 2
done
case "$WAITING" in ErrImagePull|ImagePullBackOff) ;; *) echo "[setup] ERROR: the Pod did not fail to pull the image (state: '$WAITING')"; $KC get pods -A 2>&1 | head; exit 1 ;; esac
echo "  -> the Pod waits: $WAITING"

echo "[setup] recording what is true now (digests, the Pod, the node, hashes of the files the case does not let anyone change)..."
MANIFEST_DIGEST="$($CTR images ls | awk -v r="$IMAGE" '$1 == r {print $3}')"
CONFIG_DIGEST="$($CTR content get "$MANIFEST_DIGEST" 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)["config"]["digest"])')"
echo "$MANIFEST_DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo "[setup] ERROR: no manifest digest for $IMAGE"; exit 1; }
echo "$CONFIG_DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo "[setup] ERROR: no config digest for $IMAGE"; exit 1; }
echo "$MANIFEST_DIGEST" > "$STATE_DIR/manifest.digest"
echo "$CONFIG_DIGEST" > "$STATE_DIR/config.digest"
echo "$NONCE" > "$STATE_DIR/nonce"
$KC get pods -l app=flask-proj -o jsonpath='{.items[0].metadata.uid}' > "$STATE_DIR/pod.uid"
$KC get pods -l app=flask-proj -o jsonpath='{.items[0].metadata.name}' > "$STATE_DIR/pod.name"
$KC get node "$NODE" -o jsonpath='{.metadata.uid}' > "$STATE_DIR/node.uid"
$KC get deployment "$DEPLOY" -o jsonpath='{.metadata.generation}' > "$STATE_DIR/deploy.generation"
$KC get deployment "$DEPLOY" -o jsonpath='{.metadata.uid}' > "$STATE_DIR/deploy.uid"
sudo sh -c 'cd /; sha256sum "$@" | awk "{print \$1}"' _ \
    "$RUN_BASE/config.toml" "$CERTS/docker.io/hosts.toml" "$K3S_CONFIG" "$DEMO_DIR/flaskapp.tar" "$DEMO_DIR/deployment.yaml" > "$STATE_DIR/files.sha"
sudo chmod 755 "$STATE_DIR"
sudo chmod 600 "$STATE_DIR"/*.digest "$STATE_DIR"/nonce "$STATE_DIR"/pod.* "$STATE_DIR"/node.uid "$STATE_DIR"/deploy.* "$STATE_DIR"/files.sha

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/idle" "$STATE_DIR/idle.c" "$STATE_DIR/mkdocker.py" "$STATE_DIR/patch_config.py" "$STATE_DIR/pause.tar" "$STATE_DIR/flaskapp.tar"

echo "[setup] done. ctr (namespace default) lists $IMAGE; the Pod of the Deployment cannot start from it."
