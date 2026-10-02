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

NERDCTL_VERSION="2.1.6"
BUILDKIT_VERSION="v0.23.2"

CASE_ID="bench71709053"
CTD_SOCK="/run/containerd/containerd.sock"
BK_SOCK="/run/buildkit/buildkitd.sock"
RUN_DIR="/run/$CASE_ID"
LIB_DIR="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
BASE_TAG="$CASE_ID-base:local"
CHILD_TAG="$CASE_ID-child:local"

NERDCTL="sudo nerdctl --address unix://$CTD_SOCK --namespace default"

echo "[setup] checking containerd and runc are installed (the runtime under test;"
echo "[setup] same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
containerd --version

case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    *)              ARCH="amd64" ;;
esac

echo "[setup] ensuring nerdctl and the BuildKit binaries (buildkitd, buildctl) are"
echo "[setup] installed..."
if ! command -v nerdctl >/dev/null 2>&1 || ! command -v buildkitd >/dev/null 2>&1 || ! command -v buildctl >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || {
        sudo -E apt-get update -qq
        sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl ca-certificates
    }
fi
if ! command -v nerdctl >/dev/null 2>&1; then
    echo "[setup] downloading nerdctl $NERDCTL_VERSION for linux-$ARCH ..."
    curl -fsSL -o /tmp/nerdctl.tar.gz \
        "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-${ARCH}.tar.gz"
    sudo tar Cxzf /usr/local/bin /tmp/nerdctl.tar.gz nerdctl
    rm -f /tmp/nerdctl.tar.gz
fi
if ! command -v buildkitd >/dev/null 2>&1 || ! command -v buildctl >/dev/null 2>&1; then
    echo "[setup] downloading BuildKit $BUILDKIT_VERSION for linux-$ARCH ..."
    curl -fsSL -o /tmp/buildkit.tar.gz \
        "https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-${ARCH}.tar.gz"
    sudo tar Cxzf /usr/local/bin /tmp/buildkit.tar.gz --strip-components=1 bin/buildkitd bin/buildctl
    rm -f /tmp/buildkit.tar.gz
fi
nerdctl --version
buildkitd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure containerd is running..."
sudo systemctl is-active --quiet containerd || {
    sudo systemctl reset-failed containerd 2>/dev/null || true
    sudo systemctl start containerd
}
for _ in $(seq 1 20); do
    [ -S "$CTD_SOCK" ] && break
    sleep 0.5
done
sudo ctr version >/dev/null

echo "[setup] starting BuildKit the way nerdctl expects it (socket $BK_SOCK) with its"
echo "[setup] containerd worker: it keeps the images it builds on and resolves FROM"
echo "[setup] lines against in ITS OWN containerd namespace, 'buildkit'..."
# Anything else already listening on BuildKit's default socket is in the way.
if [ -S "$BK_SOCK" ]; then
    sudo systemctl stop buildkit.service buildkit.socket 2>/dev/null || true
    sudo pkill -x buildkitd 2>/dev/null || true
    sleep 1
    sudo rm -f "$BK_SOCK"
fi
sudo mkdir -p "$RUN_DIR" "$LIB_DIR/buildkit" "$(dirname "$BK_SOCK")"
# setsid + all three fds redirected: the daemon must outlive this script and
# must not keep the harness's stdout/stderr pipes open
sudo setsid -f bash -c 'echo $$ > "$1/buildkitd.pid"; exec buildkitd --addr "unix://$2" --oci-worker=false --containerd-worker=true --containerd-worker-addr "$3" --containerd-worker-namespace=buildkit --root "$4" >"$1/buildkitd.log" 2>&1 </dev/null' \
    _ "$RUN_DIR" "$BK_SOCK" "$CTD_SOCK" "$LIB_DIR/buildkit" </dev/null >/dev/null 2>&1
for _ in $(seq 1 40); do
    [ -S "$BK_SOCK" ] && sudo buildctl --addr "unix://$BK_SOCK" debug workers >/dev/null 2>&1 && break
    sleep 0.5
done
if ! sudo buildctl --addr "unix://$BK_SOCK" debug workers >/dev/null 2>&1; then
    echo "[setup] ERROR: buildkitd did not come up; last log lines:"
    sudo tail -20 "$RUN_DIR/buildkitd.log" 2>/dev/null || true
    exit 1
fi
sudo buildctl --addr "unix://$BK_SOCK" debug workers -v | grep -E "executor|containerd.namespace" || true

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
cd "$WORK_DIR"

echo "[setup] writing the build context: a base image definition, a child image"
echo "[setup] definition that starts FROM the local base, and two small files. The base"
echo "[setup] file carries a per-run random token, so the base image's layer is"
echo "[setup] different on every run..."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
echo "bench71709053-base token=$TOKEN" > "$WORK_DIR/base.txt"
echo "bench71709053-app" > "$WORK_DIR/app.txt"
printf 'FROM scratch\nCOPY base.txt /base.txt\n' > "$WORK_DIR/Dockerfile.base"
printf 'FROM %s\nCOPY app.txt /app.txt\n' "$BASE_TAG" > "$WORK_DIR/Dockerfile.child"
echo "$TOKEN" > "$STATE_DIR/token"
(cd "$WORK_DIR" && sha256sum Dockerfile.base Dockerfile.child base.txt app.txt | sha256sum | awk '{print $1}') > "$STATE_DIR/context.sha256"

echo "[setup] building the base image earlier, with nerdctl, exactly as in the bug"
echo "[setup] report (nerdctl loads the result into ITS namespace, 'default')..."
( cd "$WORK_DIR" && $NERDCTL build -t "$BASE_TAG" -f Dockerfile.base . ) >"$STATE_DIR/base_build.out" 2>&1 || {
    echo "[setup] FAIL: building the base image failed:"; tail -15 "$STATE_DIR/base_build.out"; exit 1; }

echo "[setup] recording the base image's layers (what the child must be built on)..."
$NERDCTL image inspect "$BASE_TAG" | python3 -c '
import json, sys
d = json.load(sys.stdin)[0]
print(" ".join(d["RootFS"]["Layers"]))
' > "$STATE_DIR/base_layers"
if [ ! -s "$STATE_DIR/base_layers" ]; then
    echo "[setup] FAIL: could not read the base image's layers"
    exit 1
fi
echo "  -> base layers: $(cat "$STATE_DIR/base_layers")"

echo "[setup] trying to build the child image (this is EXPECTED to fail: BuildKit"
echo "[setup] looks for the base in its own namespace, finds nothing, and asks the"
echo "[setup] registry)..."
if ( cd "$WORK_DIR" && timeout 120 $NERDCTL build -t "$CHILD_TAG" -f Dockerfile.child . ) >"$STATE_DIR/first_attempt.out" 2>&1; then
    echo "[setup] FAIL: the child build unexpectedly succeeded; the scenario is not broken"
    exit 1
fi
grep -E "^error:" "$STATE_DIR/first_attempt.out" | head -2 | sed 's/^/  -> /'

echo "[setup] done. The base image exists for nerdctl, the child build fails."
