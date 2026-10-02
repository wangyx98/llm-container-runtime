#!/bin/bash
set -e

# Ubuntu 22.04/24.04 ship `needrestart`, which pops up an interactive
# whiptail dialog whenever apt upgrades a shared library as a dependency.
# Force both apt's own prompts and needrestart into non-interactive mode
# (same workaround used by the other cases in this benchmark).
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Only used when the host has no Docker binaries at all (see below)
DOCKER_STATIC_VERSION="27.5.1"

CASE_ID="bench66762671"
RUN_DIR="/run/$CASE_ID"
LIB_DIR="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DOCKER_SOCK="$RUN_DIR/docker.sock"
CONTAINER_NAME="$CASE_ID"
IMAGE_TAG="$CASE_ID-app:latest"
SYS_SOCK="/run/containerd/containerd.sock"

DOCKER="sudo docker -H unix://$DOCKER_SOCK"

echo "[setup] checking containerd, ctr and runc are installed (the runtime under"
echo "[setup] test; same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
containerd --version

case "$(uname -m)" in
    x86_64|amd64)   ARCH="x86_64"; IMG_ARCH="amd64" ;;
    aarch64|arm64)  ARCH="aarch64"; IMG_ARCH="arm64" ;;
    *)              ARCH="x86_64"; IMG_ARCH="amd64" ;;
esac

echo "[setup] ensuring the Docker daemon and CLI binaries exist..."
# Only the binaries are needed; the case starts its own private dockerd below,
# so a docker.service that may already exist on this host is left alone. If
# the host has no Docker at all, take the static binaries (no package manager,
# so nothing here can replace the containerd/runc packages that are installed).
if ! command -v dockerd >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || {
        sudo -E apt-get update -qq
        sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl ca-certificates
    }
    echo "[setup] downloading static Docker $DOCKER_STATIC_VERSION for $ARCH ..."
    curl -fsSL -o /tmp/docker-static.tgz \
        "https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_STATIC_VERSION}.tgz"
    sudo tar -xzf /tmp/docker-static.tgz -C /usr/local/bin --strip-components=1 \
        docker/docker docker/dockerd docker/docker-init docker/docker-proxy
    rm -f /tmp/docker-static.tgz
fi
docker --version
dockerd --version

echo "[setup] ensuring gcc is available (only to compile the small fixed"
echo "[setup] long-running program that is the container's entrypoint)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure the system containerd (what a plain 'ctr' talks to) runs..."
sudo systemctl is-active --quiet containerd || {
    sudo systemctl reset-failed containerd 2>/dev/null || true
    sudo systemctl start containerd
}
for _ in $(seq 1 20); do
    [ -S "$SYS_SOCK" ] && break
    sleep 0.5
done
sudo ctr version >/dev/null

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The
# pid file gets the pid of the daemon itself (exec keeps the pid); setsid + all
# three fds redirected so it outlives this script and does not hold the
# harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] starting the containerd that this Docker runs on. It is a private"
echo "[setup] daemon with its own socket (a random path, different on every run)"
echo "[setup] and its own state, not the system containerd..."
RAND=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
CTD_DIR="$RUN_DIR/ctd-$RAND"
CTD_SOCK="$CTD_DIR/containerd.sock"
sudo mkdir -p "$CTD_DIR/state" "$LIB_DIR/containerd" "$LIB_DIR/docker" "$RUN_DIR/exec"
sudo tee "$CTD_DIR/config.toml" >/dev/null <<CEOF
version = 2
root = "$LIB_DIR/containerd"
state = "$CTD_DIR/state"
disabled_plugins = ["io.containerd.grpc.v1.cri"]

[grpc]
  address = "$CTD_SOCK"
CEOF
start_daemon "$RUN_DIR/containerd.pid" "$RUN_DIR/containerd.log" containerd --config "$CTD_DIR/config.toml"
for _ in $(seq 1 40); do
    [ -S "$CTD_SOCK" ] && sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1; then
    echo "[setup] ERROR: the private containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_DIR/containerd.log" 2>/dev/null || true
    exit 1
fi

echo "[setup] starting dockerd (API socket $DOCKER_SOCK), pointed at that containerd..."
# --containerd makes dockerd use an existing containerd instead of the system
# one or a managed one. No bridge/iptables: the container needs no network and
# a possible system Docker on this host keeps its networking untouched.
start_daemon "$RUN_DIR/dockerd.pid" "$RUN_DIR/dockerd.log" \
    dockerd --host "unix://$DOCKER_SOCK" --pidfile "$RUN_DIR/docker.pid" \
        --data-root "$LIB_DIR/docker" --exec-root "$RUN_DIR/exec" \
        --containerd "$CTD_SOCK" \
        --bridge none --iptables=false --ip6tables=false --ip-forward=false
for _ in $(seq 1 60); do
    [ -S "$DOCKER_SOCK" ] && $DOCKER info >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $DOCKER info >/dev/null 2>&1; then
    echo "[setup] ERROR: dockerd did not come up; last log lines:"
    sudo tail -20 "$RUN_DIR/dockerd.log" 2>/dev/null || true
    exit 1
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
cd "$WORK_DIR"

echo "[setup] compiling the container's entrypoint: a static program that prints"
echo "[setup] a line once a second..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <time.h>

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        puts("bench66762671-app running");
        fflush(stdout);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
gcc -static -Os -s -o "$STATE_DIR/b66762671-app" "$STATE_DIR/app.c"
tar -C "$STATE_DIR" -cf "$STATE_DIR/rootfs.tar" b66762671-app

echo "[setup] creating the image in Docker (docker import, no registry needed)..."
$DOCKER import --change 'ENTRYPOINT ["/b66762671-app"]' "$STATE_DIR/rootfs.tar" "$IMAGE_TAG" >/dev/null

echo "[setup] starting the container under Docker..."
$DOCKER run -d --name "$CONTAINER_NAME" --network none "$IMAGE_TAG" >/dev/null
for _ in $(seq 1 20); do
    [ "$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ] && break
    sleep 0.5
done
CONTAINER_ID=$($DOCKER inspect -f '{{.Id}}' "$CONTAINER_NAME")
if ! echo "$CONTAINER_ID" | grep -qE '^[0-9a-f]{64}$'; then
    echo "[setup] FAIL: container did not start (id '$CONTAINER_ID'); dockerd log:"
    sudo tail -15 "$RUN_DIR/dockerd.log" 2>/dev/null || true
    exit 1
fi
[ "$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" = "true" ] || {
    echo "[setup] FAIL: container is not running"; exit 1; }

echo "[setup] recording the ground truth (the oracle compares the report to it)..."
echo "$CONTAINER_ID" > "$STATE_DIR/container_id"
echo "$CTD_SOCK" > "$STATE_DIR/containerd_socket"
echo "moby" > "$STATE_DIR/namespace"
if ! sudo ctr -a "$CTD_SOCK" -n moby containers ls -q | grep -qxF "$CONTAINER_ID"; then
    echo "[setup] FAIL: the Docker container is not visible in namespace moby of the private containerd"
    exit 1
fi
echo "  -> container $CONTAINER_ID, containerd socket $CTD_SOCK, namespace moby"

echo "[setup] done. Docker runs the container; a plain ctr cannot see it."
