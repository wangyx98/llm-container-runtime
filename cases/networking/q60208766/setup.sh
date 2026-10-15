#!/bin/bash
set -e

CASE_ID="bench60208766"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): helpers, registry store, certificates, token, logs
UNIT="$CASE_ID-containerd.service"
HOST="registry.$CASE_ID.test"                    # adaptation: the original pulls from the internet through the corporate proxy; the lab's registry has a test domain
REG_IP="127.0.0.2"
REG_PORT=35746
PROXY_PORT=35747
SRC_IP="127.0.0.7"                               # the only source address the registry accepts: the proxy's
API_IP="10.96.0.1"                               # the address of the Kubernetes API Service of the question (the lab puts it on the loopback interface; it is not a loopback address)
API_PORT=443
API_IF="lo:b60208766"
NODE="bench60208766-node"
ETC="/etc/$CASE_ID"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
CACHE="/var/cache/$CASE_ID"                      # the downloaded releases (kept by cleanup.sh; checked against their checksums at every setup)
CD_VERSION="2.0.0"
CALICO_VERSION="v3.20.6"                         # the last release of the stand-alone Calico CNI plugin repository (the question runs Calico 3.x)
CNI_VERSION="v1.5.1"                             # containernetworking/plugins: only the loopback plugin is used (containerd always configures the loopback of a Pod)
LABPATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the tools: runc, crictl, systemctl, openssl, curl, tar, python3..."
for c in runc crictl systemctl openssl curl tar sha256sum python3 sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found (crictl: run cases/compatibility/q59161183/setup.sh once; it installs the pinned crictl)"; exit 1; }
done
[ -d /run/systemd/system ] || echo "[setup] note: this host runs no systemd (a stand-in for systemctl is in use)"
case "$(uname -m)" in
    x86_64) ARCH=amd64; CALICO_SHA=2f95dda8d2105423212cd36c57c5b410b32a94a0dc70c279f51eae140d9ca942;;
    aarch64) ARCH=arm64; CALICO_SHA=427e303a793531efa99a2324eeca8d5b19080e953f25f6eb3edf5fae73577bd8;;
    *) echo "[setup] ERROR: no containerd $CD_VERSION / Calico $CALICO_VERSION release for $(uname -m)"; exit 1;;
esac
crictl --version | head -1
FWD=$(sudo iptables -S FORWARD 2>/dev/null | head -1 || true)
[ "$FWD" != "-P FORWARD DROP" ] || { echo "[setup] ERROR: the FORWARD policy of the firewall is DROP (Docker or ufw sets it): the Pods reach each other through the host, so the lab needs ACCEPT there (or a rule that allows 198.18.60.0/24)"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking that nothing owns $API_IP or listens on $API_PORT/$REG_PORT/$PROXY_PORT, and gcc is there (two tiny static programs, so nothing but the lab's registry has to be pulled from)..."
if python3 "$CASE_DIR/helpers/alias.py" has "$API_IF" "$API_IP"; then echo "[setup] ERROR: $API_IP is already an address of this host (a cluster of its own? the lab needs that address for the Kubernetes API Service)"; exit 1; fi
for a in "127.0.0.1:$API_PORT" "$REG_IP:$REG_PORT" "127.0.0.1:$PROXY_PORT"; do
    if (exec 3<>"/dev/tcp/${a%:*}/${a#*:}") 2>/dev/null; then echo "[setup] ERROR: something already listens on $a"; exit 1; fi
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] saving what is in the places where a solution may put a proxy variable (/etc/environment, /etc/profile.d, the manager's configuration) and the forwarding switch of the kernel, so cleanup.sh can put it back..."
BASE="$LIB/baseline"
sudo install -d -m 755 "$BASE"
if [ -e /etc/environment ]; then sudo cp -p /etc/environment "$BASE/environment"; fi
ls /etc/profile.d 2>/dev/null | sudo tee "$BASE/profile.d.list" >/dev/null
if [ -e /etc/systemd/system.conf ]; then sudo cp -p /etc/systemd/system.conf "$BASE/system.conf"; fi
if [ -d /etc/systemd/system.conf.d ]; then ls /etc/systemd/system.conf.d | sudo tee "$BASE/system.conf.d.list" >/dev/null; else sudo touch "$BASE/system.conf.d.absent" "$BASE/system.conf.d.list"; fi
cat /proc/sys/net/ipv4/ip_forward | sudo tee "$BASE/ip_forward" >/dev/null
[ -d /run/calico ] && sudo touch "$BASE/run-calico.existed"        # the Calico IPAM lock file lives there
true

echo "[setup] the releases (checked against their checksums, cached in $CACHE): containerd $CD_VERSION, the Calico $CALICO_VERSION CNI plugin and the loopback plugin of containernetworking/plugins $CNI_VERSION..."
sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = file name in the cache, $2 = URL, $3 = expected sha256 (a literal, or "url:URL" = the first field of the published checksum file; then the checksum is cached next to the file)
    local name="$1" url="$2" want="$3" tmp
    case "$want" in url:*)
        want=$(sudo cat "$CACHE/$name.sha256" 2>/dev/null || true)
        if [ "${#want}" = 64 ] && echo "$want  $CACHE/$name" | sudo sha256sum -c --status 2>/dev/null; then return 0; fi
        want=$(curl -fsSL --retry 3 --max-time 60 "${3#url:}" | awk '{print $1}');;
    esac
    [ "${#want}" = 64 ] || { echo "[setup] ERROR: no checksum for $name"; exit 1; }
    if ! echo "$want  $CACHE/$name" | sudo sha256sum -c --status 2>/dev/null; then
        sudo rm -f "$CACHE/$name"
        tmp=$(mktemp)
        curl -fsSL --retry 3 --max-time 300 -o "$tmp" "$url" || { rm -f "$tmp"; echo "[setup] ERROR: could not download $url"; exit 1; }
        sudo install -m 644 "$tmp" "$CACHE/$name"
        rm -f "$tmp"
        echo "$want  $CACHE/$name" | sudo sha256sum -c --status || { echo "[setup] ERROR: the checksum of $name is wrong"; sudo rm -f "$CACHE/$name"; exit 1; }
    fi
    case "$3" in url:*) echo "$want" | sudo tee "$CACHE/$name.sha256" >/dev/null;; esac
}
CD_TAR="containerd-$CD_VERSION-linux-$ARCH.tar.gz"
fetch "$CD_TAR" "https://github.com/containerd/containerd/releases/download/v$CD_VERSION/$CD_TAR" "url:https://github.com/containerd/containerd/releases/download/v$CD_VERSION/$CD_TAR.sha256sum"
CNI_TAR="cni-plugins-linux-$ARCH-$CNI_VERSION.tgz"
fetch "$CNI_TAR" "https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/$CNI_TAR" "url:https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/$CNI_TAR.sha256"
fetch "calico-$CALICO_VERSION-$ARCH" "https://github.com/projectcalico/cni-plugin/releases/download/$CALICO_VERSION/calico-$ARCH" "$CALICO_SHA"
sudo install -d -m 755 "$LIB" "$LIB/bin" "$LIB/cni/bin"
sudo tar -xzf "$CACHE/$CD_TAR" -C "$LIB" bin/containerd bin/ctr bin/containerd-shim-runc-v2
sudo tar -xzf "$CACHE/$CNI_TAR" -C "$LIB/cni/bin" ./loopback
sudo install -m 755 "$CACHE/calico-$CALICO_VERSION-$ARCH" "$LIB/cni/bin/calico"       # one binary: it acts as the IPAM plugin when it is started under the name calico-ipam
sudo install -m 755 "$CACHE/calico-$CALICO_VERSION-$ARCH" "$LIB/cni/bin/calico-ipam"
"$LIB/bin/containerd" --version | head -1 | grep -q " v$CD_VERSION " || { echo "[setup] ERROR: the downloaded containerd is not $CD_VERSION"; exit 1; }
"$LIB/bin/containerd" --version | head -1

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo install -d -m 700 -o root -g root "$STATE_DIR"
sudo cp "$CASE_DIR"/helpers/{pause.c,app.c,mkoci.py,registry.py,proxy.py,api.py,alias.py,lab.py,verify.py} "$STATE_DIR/"
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py proxy.py api.py alias.py lab.py verify.py | awk "{print \$1}" > helpers.sha' _ "$STATE_DIR"
install -d -m 1777 "$WORK_DIR/out"                 # the pod files of the oracle

echo "[setup] the images of the lab: a static sandbox (pause) program and a static workload program, one layer each with a random label (the digests differ per setup), OCI manifests..."
sudo gcc -static -O2 -o "$STATE_DIR/pause" "$STATE_DIR/pause.c"
sudo gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo python3 "$STATE_DIR/mkoci.py" init "$STATE_DIR/registry" "$STATE_DIR/pause" "$STATE_DIR/app" | sudo tee "$STATE_DIR/oci.json" >/dev/null

echo "[setup] a private CA and two certificates: the registry's ($HOST) and the Kubernetes API's (IP $API_IP, as the apiserver certificate of a cluster has it)..."
sudo bash -c '
set -e
cd "$1"; mkdir -p pki; cd pki
openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -x509 -new -key ca.key -days 30 -subj "/CN=bench60208766 lab CA" -out ca.crt
for n in reg api; do openssl genrsa -out $n.key 2048 2>/dev/null; done
openssl req -new -key reg.key -subj "/CN=$2" -out reg.csr
printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\n" "$2" > reg.cnf
openssl x509 -req -in reg.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile reg.cnf -out reg.crt 2>/dev/null
openssl req -new -key api.key -subj "/CN=kube-apiserver" -out api.csr
printf "subjectAltName=IP:%s,DNS:kubernetes,DNS:kubernetes.default.svc\nbasicConstraints=CA:FALSE\n" "$3" > api.cnf
openssl x509 -req -in api.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile api.cnf -out api.crt 2>/dev/null
' _ "$STATE_DIR" "$HOST" "$API_IP"
HOSTS_LINE="$REG_IP $HOST # $CASE_ID"
echo "$HOSTS_LINE" | sudo tee "$STATE_DIR/hosts_line" >/dev/null
echo "$HOSTS_LINE" | sudo tee -a /etc/hosts >/dev/null

echo "[setup] the Kubernetes API Service address $API_IP on the loopback interface (an alias, /32), and the lab's kernel switch for forwarding between Pods..."
sudo python3 "$STATE_DIR/alias.py" add "$API_IF" "$API_IP"
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null

echo "[setup] the Kubernetes API ($API_IP:$API_PORT, HTTPS, bearer token): the node, the namespaces, the Calico ClusterInformation and an IP pool (the objects of a ready cluster; Pods are added by the evaluator, as the kubelet would)..."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
echo "$TOKEN" | sudo tee "$STATE_DIR/token" >/dev/null
sudo chmod 600 "$STATE_DIR/token"
sudo python3 - "$STATE_DIR/api-seed.json" "$NODE" <<'PY'
import json, sys, secrets
out, node = sys.argv[1:3]
crd = "crd.projectcalico.org/v1"
seed = {
    "/apis/%s/clusterinformations" % crd: [{"apiVersion": crd, "kind": "ClusterInformation", "metadata": {"name": "default"},
                                             "spec": {"clusterGUID": secrets.token_hex(16), "clusterType": "k8s,bgp", "calicoVersion": "v3.20.6", "datastoreReady": True}}],
    "/apis/%s/ippools" % crd: [{"apiVersion": crd, "kind": "IPPool", "metadata": {"name": "default-ipv4-ippool"},
                                "spec": {"cidr": "198.18.60.0/24", "blockSize": 26, "ipipMode": "Never", "vxlanMode": "Never", "natOutgoing": True, "nodeSelector": "all()"}}],
    "/api/v1/nodes": [{"apiVersion": "v1", "kind": "Node", "metadata": {"name": node, "labels": {"kubernetes.io/hostname": node}}, "spec": {}, "status": {}}],
    "/api/v1/namespaces": [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": n}, "spec": {}, "status": {}} for n in ("default", "kube-system")],
}
json.dump(seed, open(out, "w"))
PY
sudo env -i PATH="$LABPATH" setsid -f python3 "$STATE_DIR/api.py" "$API_IP" "$API_PORT" "$STATE_DIR/pki/api.crt" "$STATE_DIR/pki/api.key" "$TOKEN" "$STATE_DIR/api.log" "$STATE_DIR/api-seed.json" \
    >"$WORK_DIR/api.out" 2>&1 </dev/null

echo "[setup] the controlled egress: the registry ($REG_IP:$REG_PORT, HTTPS) accepts only connections from $SRC_IP, the proxy (127.0.0.1:$PROXY_PORT, CONNECT) uses that source address; the proxy cannot reach the cluster-internal API ($API_IP:$API_PORT)..."
sudo env -i PATH="$LABPATH" setsid -f python3 "$STATE_DIR/registry.py" "$REG_IP" "$REG_PORT" "$STATE_DIR/registry" "$STATE_DIR/registry.log" "$STATE_DIR/pki/reg.crt" "$STATE_DIR/pki/reg.key" "$SRC_IP" \
    >"$WORK_DIR/registry.out" 2>&1 </dev/null
sudo env -i PATH="$LABPATH" setsid -f python3 "$STATE_DIR/proxy.py" 127.0.0.1 "$PROXY_PORT" "$STATE_DIR/proxy.log" "$SRC_IP" "$HOST" "$REG_PORT" "$API_IP" "$API_PORT" \
    >"$WORK_DIR/proxy.out" 2>&1 </dev/null
for _ in $(seq 1 40); do
    sudo curl -s --max-time 2 -o /dev/null -A bench60208766-lab --proxy "http://127.0.0.1:$PROXY_PORT" --cacert "$STATE_DIR/pki/ca.crt" "https://$HOST:$REG_PORT/v2/" && break
    sleep 0.3
done
sudo curl -sf --max-time 5 -A bench60208766-lab --proxy "http://127.0.0.1:$PROXY_PORT" --cacert "$STATE_DIR/pki/ca.crt" "https://$HOST:$REG_PORT/v2/" >/dev/null \
    || { echo "[setup] ERROR: the registry does not answer through the proxy"; cat "$WORK_DIR/registry.out" "$WORK_DIR/proxy.out"; exit 1; }
sudo curl -sf --noproxy '*' --max-time 5 -A bench60208766-lab --cacert "$STATE_DIR/pki/ca.crt" -H "Authorization: Bearer $TOKEN" "https://$API_IP:$API_PORT/apis/crd.projectcalico.org/v1/clusterinformations/default" >/dev/null \
    || { echo "[setup] ERROR: the Kubernetes API does not answer"; cat "$WORK_DIR/api.out"; exit 1; }

echo "[setup] the CNI of the node: the Calico plugin in Kubernetes datastore mode, its kubeconfig (server https://$API_IP:$API_PORT, a token), the loopback plugin..."
sudo install -d -m 755 "$ETC" "$ETC/cni/net.d" "$ETC/certs.d/$HOST:$REG_PORT" "$LIB/root" "$RUN"
sudo install -m 644 "$STATE_DIR/pki/ca.crt" "$ETC/ca.crt"
sudo tee "$ETC/cni/calico-kubeconfig" >/dev/null <<KCFG
apiVersion: v1
kind: Config
clusters:
- name: kubernetes
  cluster:
    server: https://$API_IP:$API_PORT
    certificate-authority: $ETC/ca.crt
users:
- name: calico-cni
  user:
    token: $TOKEN
contexts:
- name: calico-cni@kubernetes
  context:
    cluster: kubernetes
    user: calico-cni
current-context: calico-cni@kubernetes
KCFG
sudo chmod 600 "$ETC/cni/calico-kubeconfig"
sudo tee "$ETC/cni/net.d/10-calico.conf" >/dev/null <<NCONF
{
  "name": "k8s-pod-network",
  "cniVersion": "0.3.1",
  "type": "calico",
  "log_level": "info",
  "datastore_type": "kubernetes",
  "nodename": "$NODE",
  "nodename_file_optional": true,
  "mtu": 1440,
  "ipam": {"type": "calico-ipam"},
  "policy": {"type": "k8s"},
  "kubernetes": {"kubeconfig": "$ETC/cni/calico-kubeconfig"}
}
NCONF

echo "[setup] containerd $CD_VERSION as a private instance (not containerd.service): own root, state, CRI socket, CNI directories; registry settings in a config_path directory (the registry's CA); the proxy settings of the node in a systemd drop-in, as a corporate machine has them..."
sudo tee "$ETC/certs.d/$HOST:$REG_PORT/hosts.toml" >/dev/null <<HTOML
server = "https://$HOST:$REG_PORT"

[host."https://$HOST:$REG_PORT"]
  capabilities = ["pull", "resolve"]
  ca = "$ETC/ca.crt"
HTOML
cat <<CEOF | sudo tee "$ETC/config.toml" >/dev/null
# containerd of the lab of q60208766 (a private instance next to containerd.service). Version 3 of the configuration.
version = 3
root = "$LIB/root"
state = "$RUN/state"

[grpc]
  address = "$RUN/containerd.sock"

[plugins."io.containerd.internal.v1.opt"]
  path = "$LIB/opt"

[plugins."io.containerd.nri.v1.nri"]
  disable = true

[plugins."io.containerd.cri.v1.images".pinned_images]
  sandbox = "$HOST:$REG_PORT/pause:3.6"

[plugins."io.containerd.cri.v1.images".registry]
  config_path = "$ETC/certs.d"

[plugins."io.containerd.cri.v1.runtime"]
  restrict_oom_score_adj = true
  netns_mounts_under_state_dir = true

[plugins."io.containerd.cri.v1.runtime".cni]
  bin_dir = "$LIB/cni/bin"
  conf_dir = "$ETC/cni/net.d"
CEOF
cat <<UNIT | sudo tee "/etc/systemd/system/$UNIT" >/dev/null
[Unit]
Description=containerd $CD_VERSION of the lab $CASE_ID (a private instance; not containerd.service)
After=network.target

[Service]
Type=simple
Environment=PATH=$LIB/bin:$LABPATH
ExecStart=$LIB/bin/containerd --config $ETC/config.toml
Restart=on-failure
KillMode=process
Delegate=yes
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT
sudo install -d -m 755 "/etc/systemd/system/$UNIT.d"
cat <<DROPIN | sudo tee "/etc/systemd/system/$UNIT.d/http-proxy.conf" >/dev/null
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:$PROXY_PORT"
Environment="HTTPS_PROXY=http://127.0.0.1:$PROXY_PORT"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
DROPIN
sudo systemctl daemon-reload
sudo systemctl start "$UNIT" || { echo "[setup] ERROR: $UNIT did not start"; sudo systemctl status "$UNIT" --no-pager 2>&1 | tail -8; sudo journalctl -u "$UNIT" --no-pager -n 15 2>&1 | tail -15; exit 1; }

echo "[setup] the record of what is true (digests of the images, hashes of the binaries, the unit, the CNI files and the store, the identity of the API, the registry, the proxy and the service); the pause image is pulled through the proxy by the CRI..."
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. $UNIT (CRI socket $RUN/containerd.sock, config $ETC/config.toml, CNI Calico) cannot create a Pod sandbox: the Calico plugin it starts reaches the Kubernetes API $API_IP:$API_PORT through the node's proxy http://127.0.0.1:$PROXY_PORT."
