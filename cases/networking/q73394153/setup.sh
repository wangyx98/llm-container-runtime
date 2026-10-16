#!/bin/bash
set -e

CASE_ID="bench73394153"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): helpers, registry store, CA key, logs
ETC="/etc/$CASE_ID"                              # the "/etc" of the lab's Rancher Desktop VM
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
CACHE="/var/cache/$CASE_ID"                      # the downloaded and checked k3s and nerdctl (kept by cleanup.sh)
HOST="registry.$CASE_ID.test"                    # adaptation: the original pulls docker.io through the corporate proxy; the lab's registry has a name that only the proxy resolves
REG_IP="127.0.0.2"
REG_PORT=33941
PROXY_PORT=33942
SRC_IP="127.0.0.7"                               # the only source address the registry accepts: the proxy's
NODE="$CASE_ID-node"
LABPATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

K3S_VERSION="v1.30.5+k3s1"
NERDCTL_VERSION="2.1.3"
# release asset and sha256 per architecture (sha256sum-<arch>.txt of the k3s release, SHA256SUMS of the nerdctl release)
case "$(uname -m)" in
    x86_64)        K3S_ASSET="k3s";       K3S_SHA256="322fbdc904deb1bf2f7a4460c0ae616db3aea75b8aefe911286946cdb0893d95"
                   NERDCTL_ASSET="nerdctl-$NERDCTL_VERSION-linux-amd64.tar.gz"; NERDCTL_SHA256="227390fb16c20d6ab3a7588e5ce72202df1bec7960a2a091599ce3c1bf3fd1d8" ;;
    aarch64|arm64) K3S_ASSET="k3s-arm64"; K3S_SHA256="da3b23dc736401259f2e5ada5c481f8302d4f8a55b6d580e1abecaf85e89f2ac"
                   NERDCTL_ASSET="nerdctl-$NERDCTL_VERSION-linux-arm64.tar.gz"; NERDCTL_SHA256="62e34ce6156c942368968c0d88c731cb2f3b341785d584e56a2c175916d5f88d" ;;
    *)             K3S_ASSET=""; K3S_SHA256=""; NERDCTL_ASSET=""; NERDCTL_SHA256="" ;;
esac
OWNED_MARKER="$LIB/k3s_host_dirs_owned"

echo "[setup] checking the tools: curl, python3, gcc, openssl, tar, sha256sum, hostname, sudo..."
for c in curl python3 gcc openssl tar sha256sum hostname sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
[ -n "$K3S_ASSET" ] || { echo "[setup] ERROR: no k3s/nerdctl is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
. /etc/os-release
echo "[setup] $PRETTY_NAME, $(uname -m); k3s $K3S_VERSION and nerdctl $NERDCTL_VERSION (pinned by sha256) stand in for the k3s and nerdctl of a Rancher Desktop VM"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking this host has no k3s or kubelet of its own: k3s keeps files in fixed places (/etc/rancher, /var/lib/rancher, /var/lib/kubelet, /run/k3s), which this case manages..."
for d in /etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s; do
    [ ! -e "$d" ] || { echo "[setup] ERROR: $d exists: this host has its own k3s or kubelet state, the case would damage it"; exit 1; }
done
for c in k3s-server k3s-agent kubelet; do
    ! pgrep -x "$c" >/dev/null 2>&1 || { echo "[setup] ERROR: a $c process runs on this host: the case needs a host without k3s or a kubelet"; exit 1; }
done
for a in "$REG_IP:$REG_PORT" "127.0.0.1:$PROXY_PORT" "127.0.0.1:16443"; do
    if (exec 3<>"/dev/tcp/${a%:*}/${a#*:}") 2>/dev/null; then echo "[setup] ERROR: something already listens on $a"; exit 1; fi
done

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo install -d -m 700 -o root -g root "$STATE_DIR"
sudo cp "$CASE_DIR"/helpers/{app.c,mkoci.py,registry.py,proxy.py,lab.py,verify.py} "$STATE_DIR/"
sudo bash -c 'cd "$1" && sha256sum app.c mkoci.py registry.py proxy.py lab.py verify.py | awk "{print \$1}" > helpers.sha' _ "$STATE_DIR"

echo "[setup] k3s and nerdctl: from the cache $CACHE, else downloaded (BENCH73394153_K3S_BIN and BENCH73394153_NERDCTL_TGZ name local copies); the sha256 is checked either way..."
sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = cache file, $2 = sha256, $3 = URL, $4 = local copy from the environment (may be empty)
    if sudo test -f "$1" && echo "$2  $1" | sudo sha256sum -c - >/dev/null 2>&1; then return 0; fi
    sudo rm -f "$1"
    local tmp="$WORK_DIR/download.tmp"
    if [ -n "$4" ]; then cp "$4" "$tmp"; else
        # downloaded as the current user (not through sudo: sudo may drop the proxy settings of the user)
        curl -fsSL --retry 3 --max-time 300 -o "$tmp" "$3" || { rm -f "$tmp"; echo "[setup] ERROR: could not download $3"; exit 1; }
    fi
    echo "$2  $tmp" | sha256sum -c - >/dev/null 2>&1 || { rm -f "$tmp"; echo "[setup] ERROR: $3 has the wrong sha256"; exit 1; }
    sudo install -m 644 "$tmp" "$1"
    rm -f "$tmp"
}
fetch "$CACHE/$K3S_ASSET-$K3S_VERSION" "$K3S_SHA256" "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/$K3S_ASSET" "${BENCH73394153_K3S_BIN:-}"
fetch "$CACHE/$NERDCTL_ASSET" "$NERDCTL_SHA256" "https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_VERSION/$NERDCTL_ASSET" "${BENCH73394153_NERDCTL_TGZ:-}"

echo "[setup] the directories, the programs and the files of the lab's Rancher Desktop VM (/etc/$CASE_ID, $LIB)..."
sudo install -d -m 755 "$ETC" "$ETC/conf.d" "$ETC/provision.d" "$ETC/pki" "$ETC/certs.d/$HOST:$REG_PORT" "$RUN" "$LIB" "$LIB/bin" "$LIB/libexec" "$LIB/vm-image" "$LIB/k3s/agent/images" "$LIB/k3s/agent/etc/containerd" "$LIB/cni/net.d" "$LIB/cni/bin" /etc/rancher/k3s
sudo touch "$OWNED_MARKER"      # from here on cleanup.sh may remove the fixed k3s directories
sudo install -m 755 "$CACHE/$K3S_ASSET-$K3S_VERSION" "$LIB/bin/k3s"
sudo tar -xzf "$CACHE/$NERDCTL_ASSET" -C "$STATE_DIR" nerdctl
sudo install -m 755 "$STATE_DIR/nerdctl" "$LIB/libexec/nerdctl"
sudo rm -f "$STATE_DIR/nerdctl"
sudo install -m 755 "$CASE_DIR"/helpers/vm/{k3sctl,kubectl,nerdctl,rdrestart} "$LIB/bin/"
sudo install -m 644 "$CASE_DIR"/helpers/vm/{conf.d-k3s,profile} "$LIB/vm-image/"
sudo install -m 600 "$LIB/vm-image/conf.d-k3s" "$ETC/conf.d/k3s"
sudo install -m 600 "$LIB/vm-image/profile" "$ETC/profile"
"$LIB/bin/k3s" --version | head -1
sudo "$LIB/libexec/nerdctl" --version

echo "[setup] the credentials of the corporate proxy (random, made for this run; they come from no real account), the CA and the certificate of the registry..."
sudo python3 - "$ETC/proxy-credentials" "$STATE_DIR/credentials" <<'PYEOF'
import os
import secrets
import sys
user = "corp\\svc" + secrets.token_hex(3)                     # a domain account name: the backslash cannot stand in a proxy URL as it is
password = "Pw@" + secrets.token_hex(6) + ":/#%" + secrets.token_hex(2)   # "/", "#" and "%" cannot stand in a proxy URL as they are either
for path in sys.argv[1:]:
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write(user + "\n" + password + "\n")
PYEOF
sudo bash -c '
set -e
cd "$1"; mkdir -p pki; cd pki
openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -x509 -new -key ca.key -days 30 -subj "/CN=bench73394153 lab CA" -out ca.crt
openssl genrsa -out srv.key 2048 2>/dev/null
openssl req -new -key srv.key -subj "/CN=$2" -out srv.csr
printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\n" "$2" > ext.cnf
openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile ext.cnf -out srv.crt 2>/dev/null
' _ "$STATE_DIR" "$HOST"
sudo install -m 644 "$STATE_DIR/pki/ca.crt" "$ETC/pki/ca.crt"
sudo install -m 644 "$STATE_DIR/pki/ca.crt" "$ETC/certs.d/$HOST:$REG_PORT/ca.crt"     # the CA for nerdctl (its hosts directory)

echo "[setup] the images of the lab: one static program, an OCI image each for the Pods' sandbox (pause) and for the two repositories lab/nerdctl-app and lab/k3s-app (random labels, so the digests differ per setup)..."
sudo gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo python3 "$STATE_DIR/mkoci.py" init "$STATE_DIR/registry" "$STATE_DIR/app"
sudo python3 "$STATE_DIR/mkoci.py" export "$STATE_DIR/registry" lab/pause 1 "$CASE_ID.local/pause:1" "$LIB/k3s/agent/images/pause.tar"     # k3s imports the archives of this directory at every start

echo "[setup] the controlled egress: the registry ($HOST:$REG_PORT = $REG_IP, HTTPS; no name server resolves $HOST) accepts only connections from $SRC_IP, the corporate proxy"
echo "[setup] (127.0.0.1:$PROXY_PORT, credentials, CONNECT to the registry only) uses that source address; everything else is reset and logged..."
sudo env -i PATH="$LABPATH" setsid -f bash -c 'echo $$ > "$1"; shift; exec "$@" >"$0" 2>&1 </dev/null' "$WORK_DIR/registry.out" "$WORK_DIR/registry.pid" \
    python3 "$STATE_DIR/registry.py" "$REG_IP" "$REG_PORT" "$STATE_DIR/registry" "$STATE_DIR/registry.log" "$STATE_DIR/pki/srv.crt" "$STATE_DIR/pki/srv.key" "$SRC_IP" </dev/null >/dev/null 2>&1
sudo env -i PATH="$LABPATH" setsid -f bash -c 'echo $$ > "$1"; shift; exec "$@" >"$0" 2>&1 </dev/null' "$WORK_DIR/proxy.out" "$WORK_DIR/proxy.pid" \
    python3 "$STATE_DIR/proxy.py" 127.0.0.1 "$PROXY_PORT" "$STATE_DIR/proxy.log" "$STATE_DIR/credentials" "$SRC_IP" "$HOST" "$REG_IP" "$REG_PORT" </dev/null >/dev/null 2>&1
for _ in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PROXY_PORT") 2>/dev/null && (exec 3<>"/dev/tcp/$REG_IP/$REG_PORT") 2>/dev/null && break
    sleep 0.2
done
(exec 3<>"/dev/tcp/127.0.0.1/$PROXY_PORT") 2>/dev/null && (exec 3<>"/dev/tcp/$REG_IP/$REG_PORT") 2>/dev/null \
    || { echo "[setup] ERROR: the registry or the proxy did not start"; cat "$WORK_DIR/registry.out" "$WORK_DIR/proxy.out" 2>/dev/null; exit 1; }

echo "[setup] k3s: its configuration (/etc/rancher/k3s), the CA of the registry for its containerd (registries.yaml), the sandbox image from the images directory..."
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<CEOF
# k3s configuration of the lab's Rancher Desktop VM
data-dir: $LIB/k3s
https-listen-port: 16443
node-name: $NODE
pause-image: $CASE_ID.local/pause:1
# a small single node: no add-ons, no network plugin, nothing that touches the host's network
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
  - cgroups-per-qos=false
  - enforce-node-allocatable=
  - make-iptables-util-chains=false
CEOF
sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<CEOF
configs:
  "$HOST:$REG_PORT":
    tls:
      ca_file: $ETC/pki/ca.crt
CEOF
# Only where the process lacks CAP_SYS_RESOURCE (a sandbox, a container): the CRI plugin then must not lower the oom_score_adj of the Pod sandboxes (k3s' generated file, plus one line)
if [ "$(sudo python3 -c 'import re; print(int(re.search(r"CapEff:\s*(\w+)", open("/proc/self/status").read()).group(1), 16) >> 24 & 1)')" = 0 ]; then
    echo "[setup] note: no CAP_SYS_RESOURCE here: restrict_oom_score_adj = true in the containerd template of k3s"
    sudo tee "$LIB/k3s/agent/etc/containerd/config.toml.tmpl" >/dev/null <<CEOF
version = 2
[plugins."io.containerd.internal.v1.opt"]
  path = "$LIB/k3s/agent/containerd"
[plugins."io.containerd.grpc.v1.cri"]
  stream_server_address = "127.0.0.1"
  stream_server_port = "10010"
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
  restrict_oom_score_adj = true
  sandbox_image = "$CASE_ID.local/pause:1"
[plugins."io.containerd.grpc.v1.cri".containerd]
  snapshotter = "overlayfs"
  disable_snapshot_annotations = true
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = false
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "$LIB/k3s/agent/etc/containerd/certs.d"
CEOF
fi
sudo tee "$LIB/pod.yaml" >/dev/null <<CEOF
# a Pod of the cluster: its image comes from the registry, the way a Deployment's would
apiVersion: v1
kind: Pod
metadata:
  name: $CASE_ID-pod
  namespace: default
spec:
  hostNetwork: true
  automountServiceAccountToken: false
  nodeName: $NODE
  containers:
  - name: app
    image: $HOST:$REG_PORT/lab/k3s-app:1
    args: ["demo"]
CEOF

echo "[setup] starting k3s as the VM does (k3sctl start; no proxy anywhere in its environment) and waiting for the node $NODE to be Ready..."
sudo "$LIB/bin/k3sctl" start >/dev/null
kube() { sudo "$LIB/bin/kubectl" "$@" </dev/null; }
READY=""
for _ in $(seq 1 90); do
    READY=$(kube get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ "$READY" = "True" ] && break
    sleep 2
done
if [ "$READY" != "True" ]; then
    echo "[setup] ERROR: the node $NODE did not become Ready; last log lines of k3s:"
    sudo tail -5 "$RUN/k3s.log" 2>/dev/null | cut -c1-200
    exit 1
fi
echo "  -> node $NODE Ready, $(kube get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')"

echo "[setup] the Pod $CASE_ID-pod (image from the registry) cannot pull its image: waiting for the pull error..."
for _ in $(seq 1 60); do kube get serviceaccount default >/dev/null 2>&1 && break; sleep 1; done     # the controller makes it a moment after the node is Ready
for _ in $(seq 1 60); do kube get serviceaccount default >/dev/null 2>&1 && break; sleep 2; done     # the controller makes it a moment after the node is Ready
kube apply -f "$LIB/pod.yaml" >/dev/null
WHY=""
for _ in $(seq 1 60); do
    WHY=$(kube get pod "$CASE_ID-pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
    case "$WHY" in ErrImagePull|ImagePullBackOff) break ;; esac
    sleep 2
done
case "$WHY" in ErrImagePull|ImagePullBackOff) echo "  -> $WHY" ;; *) echo "[setup] ERROR: the Pod is not in a pull error (reason: '$WHY')"; exit 1 ;; esac

echo "[setup] the record of what is true (identity of the registry and the proxy, hashes of the files of the lab and of the credentials)..."
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. nerdctl (sudo $LIB/bin/nerdctl) and the Pod $CASE_ID-pod cannot pull from $HOST:$REG_PORT: the only way out is the corporate proxy http://127.0.0.1:$PROXY_PORT, which wants credentials and which neither k3s nor nerdctl use."
