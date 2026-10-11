#!/bin/bash
set -e

CASE_ID="bench74804543"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and logs of the node's containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root and config (not in /run: it is mounted noexec on many hosts)
K3S_SOCK="$RUN_BASE/k3s/containerd/containerd.sock"   # where the node's containerd listens: the place of the one inside K3s, under a private root
K3S_STATE="$RUN_BASE/k3s/containerd"
K3S_ROOT="$LIB_BASE/k3s/containerd"
K3S_CFG="$LIB_BASE/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record
NS="k8s.io"                           # the containerd namespace K3s and the kubelet use
REG="127.0.0.1:43741"                 # the registry the image names point at: nothing listens there but a tripwire
REF_NEW="$REG/lab/myawx:v1.0.0"       # the image of the question (version 1.0.0)
REF_OLD="$REG/lab/myawx:v0.9.0"       # an older version of the same image, in the same repository

CTR_T="sudo ctr -a $K3S_SOCK -n $NS"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking containerd, ctr and python3 are installed (the runtime under test and the usual tools)..."
for b in containerd ctr python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program in each image, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$K3S_STATE" "$K3S_ROOT" "$(dirname "$K3S_CFG")"
cp "$CASE_DIR"/helpers/* "$STATE_DIR/"
cd "$WORK_DIR"

start_daemon() {   # $1 pid file, $2 log file, rest = the command; detached, the pid file holds the pid of the daemon itself
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] starting the node's containerd (its own socket, root and state; containerd's default config for the installed version, NRI off)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$K3S_ROOT" "$K3S_STATE" "$K3S_SOCK" \
    | sudo tee "$K3S_CFG" >/dev/null
grep -q "$K3S_SOCK" "$K3S_CFG" || { echo "[setup] ERROR: could not set the socket in the containerd config"; exit 1; }
sudo sha256sum "$K3S_CFG" | awk '{print $1}' > "$STATE_DIR/config.sha"
start_daemon "$RUN_BASE/containerd.pid" "$RUN_BASE/containerd.log" containerd --config "$K3S_CFG"
for _ in $(seq 1 60); do
    [ -S "$K3S_SOCK" ] && $CTR_T version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $CTR_T version >/dev/null 2>&1; then
    echo "[setup] ERROR: the node's containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
P=$(sudo cat "$RUN_BASE/containerd.pid")
echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
echo "  -> containerd up on $K3S_SOCK"

echo "[setup] starting the tripwire on $REG (the 'registry' of the image names: it holds nothing, 404 to everything, and records every connection)..."
python3 - <<'PYEOF' || { echo "[setup] ERROR: port 43741 is in use"; exit 1; }
import socket

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 43741))
PYEOF
: > "$STATE_DIR/tripwire.log"
setsid -f bash -c 'echo $$ > "$1"; exec python3 "$2" 43741 "$3" >"$4" 2>&1 </dev/null' \
    _ "$STATE_DIR/tripwire.pid" "$STATE_DIR/tripwire.py" "$STATE_DIR/tripwire.log" "$STATE_DIR/tripwire.err" </dev/null >/dev/null 2>&1
for _ in $(seq 1 40); do
    python3 -c 'import socket; socket.create_connection(("127.0.0.1", 43741), 1).close()' 2>/dev/null && break
    sleep 0.25
done
: > "$STATE_DIR/tripwire.log"      # the probe above was a connection too: count from zero
P=$(cat "$STATE_DIR/tripwire.pid")
echo "$P $(awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/tripwire.id"

echo "[setup] building two images offline, in Docker format, each with a static program that prints the random token of its version..."
gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
mk() {   # $1 = ref, $2 = name of the record: the token is random, the archive is removed after the import
    local tok="v-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
    sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$tok" "$STATE_DIR/token.$2"
    python3 "$STATE_DIR/mkimg.py" "$1" "$tok" "$STATE_DIR/app" "$STATE_DIR/$2.tar" > "$STATE_DIR/$2.truth"
    chmod 0644 "$STATE_DIR/$2.tar"
}
mk "$REF_NEW" new
mk "$REF_OLD" old

echo "[setup] importing them into the node's containerd, namespace $NS (what 'ctr -n k8s.io image import' did on the K3s node), and removing the archives..."
for k in new old; do
    $CTR_T images import "$STATE_DIR/$k.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import the $k image"; exit 1; }
    rm -f "$STATE_DIR/$k.tar"
done
$CTR_T images ls 2>/dev/null | awk 'NR>1{print "  -> " $1 "  " $3}'

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/mkimg.py" "$STATE_DIR/patch_config.py"
(cd "$STATE_DIR" && sha256sum tripwire.py | awk '{print $1}') > "$STATE_DIR/helpers.sha"
sudo chmod 0777 "$WORK_DIR"      # the solution writes its output file here, as the current user or through sudo

echo "[setup] done. The node's containerd ($K3S_SOCK, namespace $NS) holds $REF_NEW and $REF_OLD, imported from archives that are gone; nothing listens on $REG but the tripwire."
