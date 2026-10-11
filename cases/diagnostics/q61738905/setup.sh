#!/bin/bash
set -e

CASE_ID="bench61738905"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files, logs and runtime state of the private containerd and dockerd
LIB_BASE="/var/lib/$CASE_ID"          # their roots and configs (not in /run: it is mounted noexec on many hosts)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
DSOCK="$RUN_BASE/docker.sock"         # the daemon's socket: the only fixed name; its exec root has a random part

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking containerd, runc, dockerd, docker and python3 are installed (the runtimes under test and the usual tools)..."
for b in containerd runc dockerd docker python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
dockerd --version
dockerd --help 2>&1 | grep -q -- '--config-file' || { echo "[setup] ERROR: this dockerd has no --config-file option"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir and choosing the random name of this run..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
R=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
echo "$R" > "$STATE_DIR/rand"
EXEC="$RUN_BASE/exec-$R"              # the daemon's exec root: runc keeps its runtime root below it
CDIR="$RUN_BASE/ctd-$R"               # the state directory of the containerd, with its socket
CSOCK="$CDIR/containerd.sock"
sudo mkdir -p "$RUN_BASE" "$EXEC" "$CDIR" "$LIB_BASE/containerd" "$LIB_BASE/docker" "$LIB_BASE/etc"
cp "$CASE_DIR"/helpers/{app.c,mkimg.py,patch_config.py,lab.py,verify.py} "$STATE_DIR/"
sha256sum "$STATE_DIR"/app.c "$STATE_DIR"/mkimg.py "$STATE_DIR"/patch_config.py "$STATE_DIR"/lab.py "$STATE_DIR"/verify.py | awk '{print $1}' > "$STATE_DIR/helpers.sha"
cd "$WORK_DIR"

echo "[setup] the workload: a static program that waits for ever, in a one-layer image (bench/app:1) as an archive that 'docker load' takes..."
gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
python3 "$STATE_DIR/mkimg.py" bench/app:1 "$STATE_DIR/app" "$STATE_DIR/app1.tar" > /dev/null

echo "[setup] starting the containerd of Docker (own socket $CSOCK, own root and state)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$CDIR" "$CSOCK" \
    | sudo tee "$LIB_BASE/etc/config.toml" >/dev/null
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$LIB_BASE/etc/config.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 80); do
    [ -S "$CSOCK" ] && sudo ctr -a "$CSOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo ctr -a "$CSOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the containerd did not come up:"; sudo tail -5 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] writing the configuration file of Docker (exec root, containerd, data root, no bridge network): the command line of the daemon will have only the socket and the file..."
GROUP=$(id -gn)
sudo tee "$LIB_BASE/etc/daemon.json" >/dev/null <<JSON
{
  "exec-root": "$EXEC",
  "containerd": "$CSOCK",
  "data-root": "$LIB_BASE/docker",
  "pidfile": "$RUN_BASE/docker.pid",
  "group": "$GROUP",
  "features": {"containerd-snapshotter": true},
  "bridge": "none",
  "iptables": false,
  "ip6tables": false,
  "ip-forward": false
}
JSON

echo "[setup] starting Docker (socket $DSOCK, configuration $LIB_BASE/etc/daemon.json)..."
BASH_BIN=$(command -v bash); SETSID=$(command -v setsid); DOCKERD=$(command -v dockerd)
sudo "$SETSID" -f "$BASH_BIN" -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
    _ "$RUN_BASE/dockerd.pid" "$RUN_BASE/dockerd.log" \
    "$DOCKERD" --host "unix://$DSOCK" --config-file "$LIB_BASE/etc/daemon.json" </dev/null >/dev/null 2>&1
UP=""
for _ in $(seq 1 120); do
    if docker -H "unix://$DSOCK" info >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: dockerd did not come up:"; sudo tail -8 "$RUN_BASE/dockerd.log" | cut -c1-400; exit 1; }

echo "[setup] loading the image and starting two containers with Docker..."
python3 "$STATE_DIR/lab.py" up "$DSOCK" "$WORK_DIR" || { echo "[setup] ERROR: the workload was not created"; sudo tail -5 "$RUN_BASE/dockerd.log" | cut -c1-300; exit 1; }

echo "[setup] done. Docker ($DSOCK) runs two containers; there is no find-runc-root.sh."
