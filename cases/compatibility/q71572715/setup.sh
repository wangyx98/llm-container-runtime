#!/bin/bash
set -e

CASE_ID="bench71572715"
RUN_BASE="/run/$CASE_ID"              # socket, pid files and logs of the two services
LIB_BASE="/var/lib/$CASE_ID"          # roots of the external containerd, of k3s and of its kubelet
CTL_DIR="$LIB_BASE/bin"             # control scripts (not in /run: it is mounted noexec on many hosts)
CTD_SOCK="$RUN_BASE/containerd.sock"  # the socket of the pre-installed (external) containerd
CTD_NS="default"                      # the namespace of the independent workload
WORKLOAD="bench71572715-workload"
NODE="bench71572715-node"

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ROOTFS="$STATE_DIR/rootfs"
HB_DIR="$WORK_DIR/hb"

K3S_VERSION="v1.30.5+k3s1"
# release asset name and sha256 per architecture (sha256sum-<arch>.txt of the release)
case "$(uname -m)" in
    x86_64)          K3S_ASSET="k3s";       K3S_SHA256="322fbdc904deb1bf2f7a4460c0ae616db3aea75b8aefe911286946cdb0893d95" ;;
    aarch64|arm64)   K3S_ASSET="k3s-arm64"; K3S_SHA256="da3b23dc736401259f2e5ada5c481f8302d4f8a55b6d580e1abecaf85e89f2ac" ;;
    *)               K3S_ASSET=""; K3S_SHA256="" ;;
esac
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
OWNED_MARKER="$LIB_BASE/k3s_host_dirs_owned"

CTR="sudo ctr -a $CTD_SOCK"

echo "[setup] checking containerd, ctr, runc, curl and python3 are installed (the runtime under test; same"
echo "[setup] assumption as the other containerd cases)..."
for b in containerd ctr runc curl python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version
# The workload gets no image: its user-land (a shell, cat, mv, sleep) is the host's /usr, bind-mounted
# read-only, and /bin, /sbin, /lib, /lib64 are links into it (as in the other containerd cases that need
# a shell without downloading an image). That needs a host whose /bin, /sbin and /lib are links to /usr/...
for d in bin sbin lib; do
    [ -L "/$d" ] || { echo "[setup] ERROR: /$d is not a link into /usr on this host (merged-/usr layout needed)"; exit 1; }
done
[ -x /usr/bin/sleep ] && [ -x /bin/sh ] && [ -x /usr/bin/mv ] || { echo "[setup] ERROR: sleep, mv or sh missing on the host"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking this host has no k3s or kubelet of its own: k3s keeps files in fixed places"
echo "[setup] (/etc/rancher, /var/lib/rancher, /var/lib/kubelet, /run/k3s), which this case manages..."
for d in /etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s; do
    [ ! -e "$d" ] || { echo "[setup] ERROR: $d exists: this host has its own k3s or kubelet state, the case would damage it"; exit 1; }
done
for c in k3s-server k3s-agent kubelet; do
    ! pgrep -x "$c" >/dev/null 2>&1 || { echo "[setup] ERROR: a $c process runs on this host: the case needs a host without k3s or a kubelet"; exit 1; }
done

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR"
sudo touch "$OWNED_MARKER"      # from here on cleanup.sh may remove the fixed k3s directories

echo "[setup] locating the k3s binary (the one in the PATH; else $K3S_VERSION is downloaded, and its sha256"
echo "[setup] checked)..."
K3S_BIN="${BENCH71572715_K3S_BIN:-$(command -v k3s || true)}"
if [ -z "$K3S_BIN" ]; then
    [ -n "$K3S_ASSET" ] || { echo "[setup] ERROR: k3s is not installed and no binary is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
    sudo mkdir -p "$LIB_BASE/bin"
    # downloaded as the current user (not through sudo: sudo may drop the proxy settings of the user)
    curl -fsSL --retry 3 --max-time 300 -o "$STATE_DIR/k3s.download" \
        "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/$K3S_ASSET" \
        || { echo "[setup] ERROR: could not download k3s $K3S_VERSION"; exit 1; }
    echo "$K3S_SHA256  $STATE_DIR/k3s.download" | sha256sum -c - >/dev/null 2>&1 \
        || { echo "[setup] ERROR: the downloaded k3s has the wrong sha256"; exit 1; }
    sudo install -m 755 "$STATE_DIR/k3s.download" "$LIB_BASE/bin/k3s"
    rm -f "$STATE_DIR/k3s.download"
    K3S_BIN="$LIB_BASE/bin/k3s"
fi
[ -x "$K3S_BIN" ] || { echo "[setup] ERROR: $K3S_BIN is not executable"; exit 1; }
echo "$K3S_BIN" > "$STATE_DIR/k3s.bin"
"$K3S_BIN" --version | head -1

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of
# the daemon itself (exec keeps the pid); setsid + all three fds redirected so it outlives this
# script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] building the root file system of the workload (empty directories, links into /usr, a random"
echo "[setup] token in /unique.txt)..."
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
mkdir -p "$ROOTFS"/{usr,proc,sys,dev,tmp,run,etc,hb}
chmod 1777 "$ROOTFS/tmp"
for d in bin sbin lib lib64 lib32 libx32; do
    [ -L "/$d" ] && ln -s "$(readlink "/$d")" "$ROOTFS/$d"
done
printf '%s\n' "$TOKEN" > "$ROOTFS/unique.txt"
chmod 644 "$ROOTFS/unique.txt"
sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$TOKEN" "$STATE_DIR/token"
mkdir -p "$HB_DIR"
chmod 0777 "$HB_DIR"

echo "[setup] starting the pre-installed containerd (the EXTERNAL one: own socket, root and state; containerd's"
echo "[setup] own default config for the installed version, moved into that root/state, NRI off)..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock = sys.argv[1:4]
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
    elif section == "grpc" and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif section == "ttrpc" and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        # do not require CAP_SYS_RESOURCE (absent in unprivileged or nested environments)
        line = f"{indent}restrict_oom_score_adj = true\n"
    sys.stdout.write(line)
PYEOF
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
cat <<CEOF | sudo tee "$CTL_DIR/containerdctl" >/dev/null
#!/bin/bash
# how this machine's pre-installed containerd is started and stopped: containerdctl start|stop|restart|status
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
    echo "[setup] ERROR: the external containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> containerd up on $CTD_SOCK"

echo "[setup] starting the independent workload $WORKLOAD in the namespace $CTD_NS of that containerd: a"
echo "[setup] shell that writes a counter and the token of the machine into $HB_DIR/heartbeat every second..."
timeout -k 5 90 $CTR -n "$CTD_NS" run -d --rootfs \
    --user 1234:1234 \
    --mount "type=bind,src=/usr,dst=/usr,options=rbind:ro" \
    --mount "type=bind,src=$HB_DIR,dst=/hb,options=rbind:rw" \
    "$ROOTFS" "$WORKLOAD" /bin/sh -c 'i=0; while :; do i=$((i+1)); printf "%s %s\n" "$(cat /unique.txt)" "$i" > /hb/heartbeat.tmp && mv /hb/heartbeat.tmp /hb/heartbeat; sleep 1; done' \
    </dev/null >/dev/null 2>&1 \
    || { echo "[setup] ERROR: ctr could not start the workload"; sudo tail -5 "$RUN_BASE/containerd.log" 2>/dev/null; exit 1; }
WPID=""
for _ in $(seq 1 30); do
    WPID=$($CTR -n "$CTD_NS" tasks ls 2>/dev/null | awk -v n="$WORKLOAD" '$1==n && $3=="RUNNING" {print $2}')
    [ -n "$WPID" ] && [ -s "$HB_DIR/heartbeat" ] && break
    sleep 0.5
done
[ -n "$WPID" ] && [ -s "$HB_DIR/heartbeat" ] || { echo "[setup] ERROR: the workload is not running or writes no heartbeat"; exit 1; }
echo "  -> $WORKLOAD RUNNING, pid $WPID, heartbeat: $(cat "$HB_DIR/heartbeat")"

echo "[setup] writing the k3s configuration $K3S_CONFIG (the standard place; the options of k3s without the"
echo "[setup] leading dashes) and the script that starts and stops k3s on this machine..."
sudo mkdir -p /etc/rancher/k3s
cat <<CEOF | sudo tee "$K3S_CONFIG" >/dev/null
# k3s configuration of this machine
data-dir: $LIB_BASE/k3s
https-listen-port: 16443
node-name: $NODE
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
sudo chmod 755 "$CTL_DIR/k3sctl"

echo "[setup] starting k3s, as installed by default: with its own embedded containerd. Waiting for the node"
echo "[setup] $NODE to be Ready..."
sudo "$CTL_DIR/k3sctl" start >/dev/null
kube() { sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml K3S_DATA_DIR="$LIB_BASE/k3s" "$K3S_BIN" kubectl "$@"; }
READY=""
for _ in $(seq 1 60); do
    READY=$(kube get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ "$READY" = "True" ] && break
    sleep 2
done
if [ "$READY" != "True" ]; then
    echo "[setup] ERROR: the node $NODE did not become Ready; last log lines of k3s:"
    sudo tail -5 "$RUN_BASE/k3s.log" 2>/dev/null | cut -c1-200
    exit 1
fi
EMBEDDED=$(kube get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
echo "  -> node $NODE Ready, container runtime $EMBEDDED"

echo "[setup] recording the identity of the external containerd, of the workload and of k3s (pid + start"
echo "[setup] time) and the versions of the two runtimes..."
P=$(cat "$RUN_BASE/containerd.pid")
echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
echo "$WPID $(sudo awk '{print $22}' /proc/$WPID/stat)" > "$STATE_DIR/workload.id"
P=$(cat "$RUN_BASE/k3s.pid")
echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/k3s.id"
echo "$EMBEDDED" > "$STATE_DIR/embedded.version"
$CTR version 2>/dev/null | awk '/Server:/ {f=1} f && /Version:/ {print $2; exit}' | sed 's/^v//' > "$STATE_DIR/external.version"
cp "$HB_DIR/heartbeat" "$STATE_DIR/heartbeat.0"
sudo test -s "$STATE_DIR/external.version" || { echo "[setup] ERROR: could not read the version of the external containerd"; exit 1; }

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/patch_config.py"

echo "[setup] done. k3s runs with its own embedded containerd; the pre-installed containerd and its"
echo "[setup] workload run on their own."
