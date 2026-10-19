#!/bin/bash
set -e

CASE_ID="bench76466526"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files and logs of the engineer's containerd and dockerd
LIB_BASE="/var/lib/$CASE_ID"          # bin (stack, docker, ctr), etc (the configuration of both daemons), the data of both daemons
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE="bench76466526/app:v1"          # what docker calls the image; containerd names the same image docker.io/bench76466526/app:v1

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking docker, dockerd, containerd, its shim, runc, ctr, python3 and sha256sum of this machine..."
for b in docker dockerd containerd containerd-shim-runc-v2 runc ctr python3 sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
DOCKER_BIN="$(command -v docker)"; DOCKERD_BIN="$(command -v dockerd)"; CONTAINERD_BIN="$(command -v containerd)"; CTR_BIN="$(command -v ctr)"
echo "  host: docker client $($DOCKER_BIN --version | head -1)"
echo "  host: dockerd $($DOCKERD_BIN --version | head -1)"
echo "  host: $($CONTAINERD_BIN --version | head -1), $(runc --version | head -1), $(uname -m), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
chmod 700 "$STATE_DIR"
cd "$WORK_DIR"
# the runc state of containers started by ctr lives below /run/containerd/runc (a shared place): note whether this host had /run/containerd
sudo mkdir -p "$LIB_BASE"
[ -e /run/containerd ] || sudo touch "$LIB_BASE/run_containerd_created"
sudo sh -c "ls /run/containerd/runc 2>/dev/null > \"$LIB_BASE/runc_ns.before\""

echo "[setup] installing the engineer's stack below $LIB_BASE: the scripts bin/stack, bin/docker and bin/ctr, and the configuration of containerd and dockerd..."
sudo mkdir -p "$LIB_BASE/bin" "$LIB_BASE/etc" "$LIB_BASE/containerd" "$LIB_BASE/docker" "$RUN_BASE/containerd" "$RUN_BASE/docker-exec"
cat <<CEOF | sudo tee "$LIB_BASE/etc/host.env" >/dev/null
# the programs of this host the engineer's stack uses
DOCKER=$DOCKER_BIN
DOCKERD=$DOCKERD_BIN
CONTAINERD=$CONTAINERD_BIN
CTR=$CTR_BIN
CEOF
cat <<CEOF | sudo tee "$LIB_BASE/etc/containerd.toml" >/dev/null
version = 2
root = "$LIB_BASE/containerd"
state = "$RUN_BASE/containerd"
disabled_plugins = ["io.containerd.grpc.v1.cri"]
[grpc]
  address = "$RUN_BASE/containerd.sock"
[debug]
  address = "$RUN_BASE/containerd-debug.sock"
[plugins."io.containerd.nri.v1.nri"]
  disable = true
CEOF
# docker keeps its images in its own graph-driver store (data-root/image/<driver>): "containerd-snapshotter": false. The containerd of this stack
# is only the runtime of docker's containers (namespace moby), it does not hold docker's images.
cat <<CEOF | sudo tee "$LIB_BASE/etc/daemon.json" >/dev/null
{
  "data-root": "$LIB_BASE/docker",
  "exec-root": "$RUN_BASE/docker-exec",
  "containerd": "$RUN_BASE/containerd.sock",
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "features": {"containerd-snapshotter": false},
  "bridge": "none",
  "iptables": false,
  "ip6tables": false,
  "ip-forward": false,
  "userland-proxy": false
}
CEOF
cat <<'CEOF' | sudo tee "$LIB_BASE/bin/stack" >/dev/null
#!/bin/sh
# The engineer's container stack: a containerd on /run/bench76466526/containerd.sock and, on top of it, a dockerd on /run/bench76466526/docker.sock.
#   stack start | stop | restart | status
L=/var/lib/bench76466526
R=/run/bench76466526
. $L/etc/host.env

daemon_stop() {     # $1 = pid file
    [ -f "$1" ] || return 0
    pid=$(cat "$1"); kill "$pid" 2>/dev/null
    for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$pid" 2>/dev/null; rm -f "$1"
}
case "$1" in
stop)
    daemon_stop $R/dockerd.pid
    daemon_stop $R/containerd.pid
    ;;
start)
    mkdir -p $R/containerd $R/docker-exec
    setsid sh -c 'echo $$ > "$1"; shift; exec "$@"' sh $R/containerd.pid \
        $CONTAINERD --config $L/etc/containerd.toml >>$R/containerd.log 2>&1 </dev/null &
    for _ in $(seq 1 100); do [ -S $R/containerd.sock ] && break; sleep 0.2; done
    setsid sh -c 'echo $$ > "$1"; shift; exec "$@"' sh $R/dockerd.pid \
        $DOCKERD --config-file $L/etc/daemon.json --host unix://$R/docker.sock --pidfile $R/dockerd-real.pid >>$R/dockerd.log 2>&1 </dev/null &
    for _ in $(seq 1 150); do $DOCKER -H unix://$R/docker.sock version >/dev/null 2>&1 && break; sleep 0.3; done
    $DOCKER -H unix://$R/docker.sock version >/dev/null 2>&1 || { echo "stack: dockerd did not come up, see $R/dockerd.log" >&2; exit 1; }
    ;;
restart)
    $0 stop; $0 start
    ;;
status)
    for n in containerd dockerd; do
        pid=$(cat $R/$n.pid 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "$n: running (pid $pid)"; else echo "$n: not running"; fi
    done
    ;;
*)
    echo "usage: stack start|stop|restart|status" >&2; exit 2
    ;;
esac
CEOF
cat <<'CEOF' | sudo tee "$LIB_BASE/bin/docker" >/dev/null
#!/bin/sh
# the docker client of the engineer's daemon
. /var/lib/bench76466526/etc/host.env
exec $DOCKER -H unix:///run/bench76466526/docker.sock "$@"
CEOF
cat <<'CEOF' | sudo tee "$LIB_BASE/bin/ctr" >/dev/null
#!/bin/sh
# ctr aimed at the containerd of the engineer's stack (the namespace is "default" unless -n or CONTAINERD_NAMESPACE says otherwise)
. /var/lib/bench76466526/etc/host.env
exec $CTR -a /run/bench76466526/containerd.sock "$@"
CEOF
sudo chmod 755 "$LIB_BASE/bin/stack" "$LIB_BASE/bin/docker" "$LIB_BASE/bin/ctr"

# ---- the image: a static program that prints its name and a nonce chosen now, and exits; a docker archive made here (nothing is pulled)
echo "[setup] building the image offline (one static program with a nonce of this setup, a docker archive for docker load)..."
NONCE="$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>

int main(void) {
    printf("bench76466526-app nonce=%s\n", NONCE);
    fflush(stdout);
    return 0;
}
CEOF
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
gcc -static -Os -s -w -DNONCE="\"$NONCE\"" -o "$STATE_DIR/app" "$STATE_DIR/app.c"
cat > "$STATE_DIR/mkarchive.py" <<'PYEOF'
"""mkarchive.py OUT REF PROGRAM : a one-layer docker archive (docker save format) with PROGRAM as /app"""
import hashlib
import io
import json
import os
import sys
import tarfile

out, ref, prog = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    with open(prog, "rb") as f:
        data = f.read()
    ti = tarfile.TarInfo("app")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Entrypoint": ["/app"], "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps([{"Config": sha(config) + ".json", "RepoTags": [ref], "Layers": [sha(layer) + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for name, payload in (("manifest.json", manifest), (sha(config) + ".json", config), (sha(layer) + "/layer.tar", layer)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(payload), 1700000000
        t.addfile(ti, io.BytesIO(payload))
PYEOF
python3 "$STATE_DIR/mkarchive.py" "$STATE_DIR/app.tar" "$IMAGE" "$STATE_DIR/app"

# ---- the engineer's steps: the stack started, the image loaded into docker (docker load)
DOCKER="$LIB_BASE/bin/docker"
CTR="$LIB_BASE/bin/ctr"
echo "[setup] starting the engineer's stack (containerd and dockerd on their own sockets; the docker of this host is not touched)..."
sudo "$LIB_BASE/bin/stack" start >"$STATE_DIR/stack.out" 2>&1 \
    || { echo "[setup] ERROR: the stack did not start:"; cat "$STATE_DIR/stack.out"; tail -20 "$RUN_BASE/dockerd.log" "$RUN_BASE/containerd.log" 2>/dev/null; exit 1; }
sudo "$DOCKER" load -i "$STATE_DIR/app.tar" >"$STATE_DIR/load.log" 2>&1 || true
IMAGE_ID="$(sudo "$DOCKER" image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null | head -1)"
if [ -z "$IMAGE_ID" ]; then
    echo "[setup] ERROR: docker could not load the image:"; head -30 "$STATE_DIR/load.log"; tail -20 "$RUN_BASE/dockerd.log"; exit 1
fi
echo "  -> docker has $IMAGE ($IMAGE_ID)"
DRIVER="$(sudo "$DOCKER" info --format '{{.Driver}}' 2>/dev/null)"
if sudo "$DOCKER" info 2>/dev/null | grep -qi "io.containerd.snapshotter"; then
    echo "[setup] ERROR: this docker uses the containerd image store although daemon.json turns it off:"; sudo "$DOCKER" info 2>/dev/null | grep -iE "Storage Driver|snapshotter|driver-type"; exit 1
fi
echo "  -> docker's store: graph driver $DRIVER (classic image store)"
sudo "$DOCKER" image inspect --format '{{json .RootFS.Layers}}' "$IMAGE" > "$STATE_DIR/layers.json"

echo "[setup] recording what is true now..."
echo "$IMAGE_ID" > "$STATE_DIR/image.id"
echo "$NONCE" > "$STATE_DIR/nonce"
echo "$DRIVER" > "$STATE_DIR/driver"
( cd "$LIB_BASE" && sudo sha256sum bin/stack bin/docker bin/ctr etc/host.env etc/containerd.toml etc/daemon.json ) > "$STATE_DIR/files.sha"
chmod 600 "$STATE_DIR"/image.id "$STATE_DIR"/nonce "$STATE_DIR"/driver "$STATE_DIR"/files.sha "$STATE_DIR"/layers.json

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/mkarchive.py" "$STATE_DIR/app.tar" "$STATE_DIR/load.log" "$STATE_DIR/stack.out"

echo "[setup] done. Docker has the image in its own store; containerd has none of it."
