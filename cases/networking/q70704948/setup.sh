#!/bin/bash
set -e

CASE_ID="bench70704948"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): helpers, CA key, logs, the download site's file
ETC="/etc/$CASE_ID"                              # the "/etc" of the lab's Rancher Desktop VM
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
CACHE="/var/cache/$CASE_ID"                      # the downloaded and checked BuildKit and nerdctl (kept by cleanup.sh)
DIST="dists.$CASE_ID.test"                       # adaptation: the original downloads from services.gradle.org; the lab's download site has a name that only the corporate name server knows
PORT=43670
CORP_NS="10.249.70.2"                            # the corporate name server and, at the same address, the download site (addresses of the VM's loopback)
STALE_NS="10.249.70.3"                           # the old resolver: knows no internal name
LABPATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

BUILDKIT_VERSION="v0.23.2"
NERDCTL_VERSION="2.1.3"
# release asset and sha256 per architecture (SHA256SUMS of the nerdctl release; the BuildKit release publishes no checksum file for the archives: the digests below are those of the release assets)
case "$(uname -m)" in
    x86_64)        BK_ASSET="buildkit-$BUILDKIT_VERSION.linux-amd64.tar.gz"; BK_SHA256="2771c3403e3a1f75a83cde387a05365794d3b900c355e864772a36c3ce541f82"
                   NERDCTL_ASSET="nerdctl-$NERDCTL_VERSION-linux-amd64.tar.gz"; NERDCTL_SHA256="227390fb16c20d6ab3a7588e5ce72202df1bec7960a2a091599ce3c1bf3fd1d8" ;;
    aarch64|arm64) BK_ASSET="buildkit-$BUILDKIT_VERSION.linux-arm64.tar.gz"; BK_SHA256="6385ff70b2fb4134b50ac3183eea3a0b06c6f6129173940d73178ae0477368f1"
                   NERDCTL_ASSET="nerdctl-$NERDCTL_VERSION-linux-arm64.tar.gz"; NERDCTL_SHA256="62e34ce6156c942368968c0d88c731cb2f3b341785d584e56a2c175916d5f88d" ;;
    *)             BK_ASSET=""; BK_SHA256=""; NERDCTL_ASSET=""; NERDCTL_SHA256="" ;;
esac

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the tools: curl, python3, openssl, tar, sha256sum, ldd, nsenter, unshare, containerd, runc, sudo..."
for c in curl python3 openssl tar sha256sum ldd nsenter unshare containerd runc sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
[ -n "$BK_ASSET" ] || { echo "[setup] ERROR: no BuildKit/nerdctl is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
if ! command -v unzip >/dev/null 2>&1; then      # the base image of the lab is made of this machine's tools, and gradlew unpacks the distribution with unzip
    echo "[setup] unzip is missing: installing it..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" unzip >/dev/null
fi
. /etc/os-release
echo "[setup] $PRETTY_NAME, $(uname -m); BuildKit $BUILDKIT_VERSION and nerdctl $NERDCTL_VERSION (pinned by sha256) stand in for the BuildKit and the nerdctl of a Rancher Desktop VM"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo install -d -m 700 -o root -g root "$STATE_DIR"
sudo cp "$CASE_DIR"/helpers/{netcfg.py,dns.py,dist.py,mkproject.py,mkbase.py,patch_config.py,lab.py,verify.py} "$STATE_DIR/"
sudo bash -c 'cd "$1" && sha256sum netcfg.py dns.py dist.py mkproject.py mkbase.py patch_config.py lab.py verify.py | awk "{print \$1}" > helpers.sha' _ "$STATE_DIR"

echo "[setup] BuildKit and nerdctl: from the cache $CACHE, else downloaded (BENCH70704948_BUILDKIT_TGZ and BENCH70704948_NERDCTL_TGZ name local copies); the sha256 is checked either way..."
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
fetch "$CACHE/$BK_ASSET" "$BK_SHA256" "https://github.com/moby/buildkit/releases/download/$BUILDKIT_VERSION/$BK_ASSET" "${BENCH70704948_BUILDKIT_TGZ:-}"
fetch "$CACHE/$NERDCTL_ASSET" "$NERDCTL_SHA256" "https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_VERSION/$NERDCTL_ASSET" "${BENCH70704948_NERDCTL_TGZ:-}"

echo "[setup] the directories, the programs and the CNI plugins of the lab's Rancher Desktop VM (/etc/$CASE_ID, $LIB)..."
sudo install -d -m 755 "$ETC" "$ETC/cni.d" "$ETC/pki" "$RUN" "$LIB" "$LIB/bin" "$LIB/libexec" "$LIB/cni-bin"
sudo tar -xzf "$CACHE/$BK_ASSET" -C "$LIB/libexec" --strip-components=1 bin/buildkitd bin/buildctl bin/buildkit-cni-bridge bin/buildkit-cni-host-local bin/buildkit-cni-loopback
sudo tar -xzf "$CACHE/$NERDCTL_ASSET" -C "$LIB/libexec" nerdctl
for p in bridge host-local loopback; do sudo ln -sf "$LIB/libexec/buildkit-cni-$p" "$LIB/cni-bin/$p"; done    # the CNI plugins of BuildKit's release are the standard ones
sudo install -m 755 "$CASE_DIR"/helpers/vm/{nerdctl,buildkitctl} "$LIB/bin/"
"$LIB/libexec/buildkitd" --version
sudo "$LIB/libexec/nerdctl" --version

echo "[setup] the CA and the certificate of the download site ($DIST)..."
sudo bash -c '
set -e
cd "$1"; mkdir -p pki; cd pki
openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -x509 -new -key ca.key -days 30 -subj "/CN=bench70704948 lab CA" -out ca.crt
openssl genrsa -out srv.key 2048 2>/dev/null
openssl req -new -key srv.key -subj "/CN=$2" -out srv.csr
printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\n" "$2" > ext.cnf
openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile ext.cnf -out srv.crt 2>/dev/null
' _ "$STATE_DIR" "$DIST"
sudo install -m 644 "$STATE_DIR/pki/ca.crt" "$ETC/pki/ca.crt"

echo "[setup] the project (a Dockerfile, a stand-in of the Gradle wrapper, a minimal source tree) and the Gradle distribution gradle-7.0.2-bin.zip with its sha256 (a fixed file, served by the lab only)..."
sudo install -d -m 755 "$LIB/project"
sudo python3 "$STATE_DIR/mkproject.py" "$LIB/project" "$STATE_DIR/gradle-7.0.2-bin.zip" "$STATE_DIR/project.json" "$DIST" "$PORT"
sudo chmod -R a+rX "$LIB/project"

echo "[setup] the base image of the project (the tools of this machine in one layer, the lab's CA as the only certificate authority; nothing is pulled)..."
sudo python3 "$STATE_DIR/mkbase.py" "$ETC/pki/ca.crt" "$STATE_DIR/base.tar" "localhost/$CASE_ID-base:1" >/dev/null

echo "[setup] the VM: a network and mount namespace of its own (nothing of the machine's network is touched), the loopback addresses $CORP_NS (corporate name server and download site) and $STALE_NS (old resolver)..."
sudo setsid -f unshare --net --mount --propagation private bash -c 'echo $$ > "$1"; exec sleep infinity' _ "$RUN/anchor.pid" </dev/null >/dev/null 2>&1
for _ in $(seq 1 50); do [ -s "$RUN/anchor.pid" ] && break; sleep 0.1; done
ANCHOR=$(sudo cat "$RUN/anchor.pid")
echo "$ANCHOR $(sudo awk '{print $22}' /proc/$ANCHOR/stat)" | sudo tee "$RUN/anchor.id" >/dev/null
in_vm() { sudo nsenter --target "$ANCHOR" --net --mount -- "$@"; }
start_in_vm() {   # $1 = pid file, $2 = log, then the command; clean environment, own session
    local pidf="$1" log="$2"; shift 2
    sudo setsid -f nsenter --target "$ANCHOR" --net --mount -- env -i HOME=/root PATH="$LABPATH" \
        bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' _ "$pidf" "$log" "$@" </dev/null >/dev/null 2>&1
}
in_vm python3 "$STATE_DIR/netcfg.py" "$CORP_NS" "$STALE_NS" >/dev/null
# nerdctl keeps the network namespaces of its containers as files in /run/netns: the VM gets a directory of its own there (mounted in its private mount namespace only), which goes with $RUN
sudo install -d -m 755 "$RUN/netns"
[ -d /run/netns ] || sudo touch "$RUN/netns_created"      # cleanup.sh removes the empty /run/netns again when this case made it
in_vm bash -c 'mkdir -p /run/netns && mount --bind "$1" /run/netns' _ "$RUN/netns"

echo "[setup] the corporate name server ($CORP_NS:53: knows $DIST), the old resolver ($STALE_NS:53: NXDOMAIN for everything) and the download site ($CORP_NS:$PORT, HTTPS)..."
start_in_vm "$WORK_DIR/dns-corp.pid" "$WORK_DIR/dns-corp.out" python3 "$STATE_DIR/dns.py" "$CORP_NS" "$STATE_DIR/dns-corp.log" corp "$DIST" "$CORP_NS"
start_in_vm "$WORK_DIR/dns-stale.pid" "$WORK_DIR/dns-stale.out" python3 "$STATE_DIR/dns.py" "$STALE_NS" "$STATE_DIR/dns-stale.log" stale
start_in_vm "$WORK_DIR/dist.pid" "$WORK_DIR/dist.out" python3 "$STATE_DIR/dist.py" "$CORP_NS" "$PORT" "$STATE_DIR/gradle-7.0.2-bin.zip" "$STATE_DIR/pki/srv.crt" "$STATE_DIR/pki/srv.key" "$STATE_DIR/dist.log"
for _ in $(seq 1 50); do
    in_vm bash -c "(exec 3<>/dev/tcp/$CORP_NS/$PORT) 2>/dev/null && (exec 3<>/dev/tcp/$CORP_NS/53) 2>/dev/null && (exec 3<>/dev/tcp/$STALE_NS/53) 2>/dev/null" && break
    sleep 0.2
done
in_vm bash -c "(exec 3<>/dev/tcp/$CORP_NS/$PORT) 2>/dev/null && (exec 3<>/dev/tcp/$CORP_NS/53) 2>/dev/null && (exec 3<>/dev/tcp/$STALE_NS/53) 2>/dev/null" \
    || { echo "[setup] ERROR: the name servers or the download site did not start"; sudo cat "$WORK_DIR"/*.out 2>/dev/null; exit 1; }

echo "[setup] the configuration of the VM: buildkitd.toml (BuildKit's network: CNI bridge, DNS section), nerdctl.toml (the DNS of containers), the CNI networks..."
sudo tee "$ETC/buildkitd.toml" >/dev/null <<CEOF
# BuildKit of the lab's Rancher Desktop VM (read when buildkitd starts: sudo $LIB/bin/buildkitctl restart)
[worker.oci]
  enabled = false

[worker.containerd]
  enabled = true
  address = "$RUN/containerd.sock"
  namespace = "$CASE_ID"
  networkMode = "cni"
  cniConfigPath = "$ETC/cni.conflist"
  cniBinaryPath = "$LIB/cni-bin"
  defaultCgroupParent = "$CASE_ID-bk"

# the name servers of the build containers (their /etc/resolv.conf)
[dns]
  nameservers = ["$STALE_NS"]
CEOF
sudo tee "$ETC/nerdctl.toml" >/dev/null <<CEOF
# nerdctl of the lab's Rancher Desktop VM
namespace = "$CASE_ID"
address = "$RUN/containerd.sock"
data_root = "$LIB/nerdctl"
cni_path = "$LIB/cni-bin"
cni_netconfpath = "$ETC/cni.d"
cgroup_manager = "cgroupfs"
# the name servers of the containers of "nerdctl run"
dns = ["$CORP_NS"]
CEOF
sudo tee "$ETC/cni.conflist" >/dev/null <<'CEOF'
{"cniVersion": "1.0.0", "name": "buildkit", "plugins": [
  {"type": "bridge", "bridge": "bench70-bk0", "isGateway": true, "isDefaultGateway": true, "ipMasq": false,
   "ipam": {"type": "host-local", "ranges": [[{"subnet": "10.249.71.0/24"}]]}}]}
CEOF
sudo tee "$ETC/cni.d/10-$CASE_ID.conflist" >/dev/null <<'CEOF'
{"cniVersion": "1.0.0", "name": "bridge", "nerdctlID": "bench70704948", "nerdctlLabels": {"nerdctl/default-network": "true"}, "plugins": [
  {"type": "bridge", "bridge": "bench70-run0", "isGateway": true, "ipMasq": false,
   "ipam": {"type": "host-local", "ranges": [[{"gateway": "10.249.70.129", "subnet": "10.249.70.128/25"}]], "routes": [{"dst": "0.0.0.0/0"}]}}]}
CEOF
sudo bash -c 'cd "$1" && sha256sum buildkitd.toml nerdctl.toml > "$2/config.sha"' _ "$ETC" "$STATE_DIR"

echo "[setup] containerd of the VM (own socket, root and state; the namespace $CASE_ID is the VM's)..."
sudo install -d -m 755 "$LIB/containerd" "$LIB/etc"
containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$LIB/containerd" "$RUN" "$RUN/containerd.sock" | sudo tee "$LIB/etc/containerd.toml" >/dev/null
start_in_vm "$RUN/containerd.pid" "$RUN/containerd.log" containerd --config "$LIB/etc/containerd.toml"
for _ in $(seq 1 60); do sudo ctr -a "$RUN/containerd.sock" version >/dev/null 2>&1 && break; sleep 0.5; done
sudo ctr -a "$RUN/containerd.sock" version >/dev/null 2>&1 || { echo "[setup] ERROR: containerd of the VM did not come up"; sudo tail -5 "$RUN/containerd.log"; exit 1; }

echo "[setup] buildkitd of the VM and the base image..."
sudo "$LIB/bin/buildkitctl" start || { echo "[setup] ERROR: buildkitd did not start"; exit 1; }
sudo "$LIB/bin/nerdctl" load -i "$STATE_DIR/base.tar" >/dev/null || { echo "[setup] ERROR: the base image could not be loaded"; exit 1; }

echo "[setup] recording the lab..."
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the record of the lab could not be written"; exit 1; }

echo "[setup] done. The VM: buildkitd (config $ETC/buildkitd.toml, control $LIB/bin/buildkitctl), nerdctl ($LIB/bin/nerdctl), project $LIB/project; download site https://$DIST:$PORT."
