#!/bin/bash
set -e

CONTAINER="bench73631968"
WORK_DIR="/tmp/bench73631968"
BAD_PORT=18973
IMAGE="docker.io/library/busybox:1.36"
DUMMY_MARKER="DUMMY_SERVICE_bench73631968_DO_NOT_TOUCH"
CONTAINER_MARKER="CONTAINER_CONTENT_bench73631968"

echo "[setup] ensuring nerdctl is installed..."
if ! command -v nerdctl >/dev/null 2>&1; then
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64) NA="amd64" ;;
        aarch64|arm64) NA="arm64" ;;
        *) echo "[setup] unsupported architecture: $ARCH"; exit 1 ;;
    esac
    TAG=$(curl -fsSL https://api.github.com/repos/containerd/nerdctl/releases/latest \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")
    VER="${TAG#v}"
    echo "[setup] downloading nerdctl $TAG for linux-$NA ..."
    curl -fsSL -o /tmp/nerdctl.tar.gz \
        "https://github.com/containerd/nerdctl/releases/download/${TAG}/nerdctl-${VER}-linux-${NA}.tar.gz"
    sudo tar Cxzf /usr/local/bin /tmp/nerdctl.tar.gz nerdctl
fi

echo "[setup] ensuring CNI plugins (bridge/portmap/etc) are installed..."
if [ ! -x /opt/cni/bin/bridge ] || [ ! -x /opt/cni/bin/portmap ]; then
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64) CA="amd64" ;;
        aarch64|arm64) CA="arm64" ;;
        *) echo "[setup] unsupported architecture: $ARCH"; exit 1 ;;
    esac
    CNI_TAG=$(curl -fsSL https://api.github.com/repos/containernetworking/plugins/releases/latest \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")
    echo "[setup] downloading CNI plugins $CNI_TAG for linux-$CA ..."
    curl -fsSL -o /tmp/cni-plugins.tgz \
        "https://github.com/containernetworking/plugins/releases/download/${CNI_TAG}/cni-plugins-linux-${CA}-${CNI_TAG}.tgz"
    sudo mkdir -p /opt/cni/bin
    sudo tar Cxzf /opt/cni/bin /tmp/cni-plugins.tgz
fi

echo "[setup] resetting work dir and any leftover state (idempotency)..."
pkill -f "http.server $BAD_PORT" 2>/dev/null || true
sudo nerdctl rm -f "$CONTAINER" >/dev/null 2>&1 || true
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/dummy_site" "$WORK_DIR/container_site"

echo "$DUMMY_MARKER" > "$WORK_DIR/dummy_site/index.html"
echo "$CONTAINER_MARKER" > "$WORK_DIR/container_site/index.html"

echo "[setup] starting the pre-existing host service that is already squatting on"
echo "[setup] port $BAD_PORT (mirrors the SO scenario, where 'limactl' was already"
echo "[setup] listening on the port nerdctl was told to publish to)..."
nohup python3 -m http.server "$BAD_PORT" --bind 0.0.0.0 --directory "$WORK_DIR/dummy_site" \
    > "$WORK_DIR/dummy_service.log" 2>&1 < /dev/null &
echo $! > "$WORK_DIR/.dummy_pid"
sleep 1

echo "[setup] confirming the pre-existing service really is listening on $BAD_PORT..."
curl -fsS "http://127.0.0.1:$BAD_PORT/" | grep -q "$DUMMY_MARKER"
echo "  -> OK"

echo "[setup] pulling $IMAGE ..."
sudo nerdctl pull "$IMAGE"

echo "[setup] starting the target container, published to the SAME (already-occupied)"
echo "[setup] port -- this is EXPECTED to fail, exactly like the original bug report..."
if sudo nerdctl run -d --name "$CONTAINER" \
    -p "${BAD_PORT}:80" \
    -v "$WORK_DIR/container_site:/www" \
    "$IMAGE" busybox httpd -f -p 80 -h /www \
    < /dev/null > "$WORK_DIR/nerdctl_run.log" 2>&1
then
    echo "[setup] unexpected: nerdctl actually managed to start the container on the"
    echo "[setup] already-occupied port -- this environment doesn't reproduce the bug"
    echo "[setup] the way this case expects."
    exit 1
fi

echo "[setup] confirmed: nerdctl correctly refused to start (port already allocated):"
cat "$WORK_DIR/nerdctl_run.log"

echo "[setup] removing the half-created container object left behind by the failed attempt..."
sudo nerdctl rm -f "$CONTAINER" >/dev/null 2>&1 || true

echo "[setup] done. No container named '$CONTAINER' exists yet; port $BAD_PORT is"
echo "[setup] occupied by the pre-existing service that must not be touched."

#echo "[setup] confirmed: nerdctl correctly refused to start (port already allocated):"
#cat "$WORK_DIR/nerdctl_run.log"

#echo "[setup] done. No container named '$CONTAINER' exists yet; port $BAD_PORT is"
#echo "[setup] occupied by the pre-existing service that must not be touched."

#sudo nerdctl run -d --name "$CONTAINER" \
   # -p "${BAD_PORT}:80" \
   # -v "$WORK_DIR/container_site:/www" \
   # "$IMAGE" busybox httpd -f -p 80 -h /www \
   # < /dev/null > /dev/null 2>&1

#sleep 1
#echo "[setup] confirming the container itself is up (nerdctl's own view)..."
#sudo nerdctl ps | grep -q "$CONTAINER"
#echo "  -> OK"

#echo "[setup] done. Container '$CONTAINER' is running but published to a port that a"
#echo "[setup] pre-existing host service ($BAD_PORT) already occupies."
