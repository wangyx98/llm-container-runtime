#!/bin/bash
set -e

CASE_ID="bench78821163"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # socket, pid files and state of the private containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root, the registry's blobs, the certificates, the CNI plugins, the data of the inner Docker (not in /run: it is mounted noexec on many hosts)
CACHE="/var/cache/$CASE_ID"           # the downloaded CNI plugins (kept by cleanup.sh; checked against their checksum at every setup)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
APP_DIR="$WORK_DIR/app"               # the Go program of the question (the one the solution changes)
SOCK="$RUN_BASE/containerd.sock"
CNI_VERSION="v1.5.1"                  # containernetworking/plugins: bridge, host-local and loopback make the pod network
GO_MIN="1.23"                         # what the pinned SDK (containerd v2.0.5) asks of the Go toolchain

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

echo "[setup] checking the tools: containerd, ctr, runc, dockerd, docker (the engine that the DIND image of the lab is made from), go, gcc, openssl, nsenter, unshare, python3..."
for b in containerd ctr runc dockerd docker containerd-shim-runc-v2 go gcc openssl nsenter unshare tar curl sha256sum python3 sudo; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
[ -x /usr/libexec/docker/docker-init ] || command -v docker-init >/dev/null || { echo "[setup] ERROR: docker-init not found (it is part of the Docker engine)"; exit 1; }
command -v go >/dev/null || { echo "[setup] ERROR: go not found in PATH (needs Go >= $GO_MIN: curl -fsSL https://go.dev/dl/go1.23.4.linux-arm64.tar.gz | sudo tar -C /usr/local -xzf -, then sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go)"; exit 1; }
GOV=$(go env GOVERSION)
python3 - "$GOV" "$GO_MIN" <<'PYEOF' || { echo "[setup] ERROR: Go ($GOV) is older than $GO_MIN"; exit 1; }
import re
import sys

have = [int(x) for x in re.match(r"go(\d+)\.(\d+)", sys.argv[1]).groups()]
need = [int(x) for x in sys.argv[2].split(".")]
sys.exit(0 if have >= need else 1)
PYEOF
containerd --version | head -1; dockerd --version
case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1;; esac

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] the CNI plugins $CNI_VERSION (checked against the published checksum, cached in $CACHE)..."
sudo install -d -m 755 "$CACHE"
CNI_TAR="cni-plugins-linux-$ARCH-$CNI_VERSION.tgz"
CNI_URL="https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/$CNI_TAR"
want=$(sudo cat "$CACHE/$CNI_TAR.sha256" 2>/dev/null || true)
if ! { [ "${#want}" = 64 ] && echo "$want  $CACHE/$CNI_TAR" | sudo sha256sum -c --status 2>/dev/null; }; then
    want=$(curl -fsSL --retry 3 --max-time 60 "$CNI_URL.sha256" | awk '{print $1}')
    [ "${#want}" = 64 ] || { echo "[setup] ERROR: no checksum for $CNI_TAR"; exit 1; }
    sudo rm -f "$CACHE/$CNI_TAR"
    tmp=$(mktemp)
    curl -fsSL --retry 3 --max-time 300 -o "$tmp" "$CNI_URL" || { rm -f "$tmp"; echo "[setup] ERROR: could not download $CNI_URL"; exit 1; }
    sudo install -m 644 "$tmp" "$CACHE/$CNI_TAR"; rm -f "$tmp"
    echo "$want  $CACHE/$CNI_TAR" | sudo sha256sum -c --status || { echo "[setup] ERROR: the checksum of $CNI_TAR is wrong"; sudo rm -f "$CACHE/$CNI_TAR"; exit 1; }
    echo "$want" | sudo tee "$CACHE/$CNI_TAR.sha256" >/dev/null
fi
sudo install -d -m 755 "$LIB_BASE" "$LIB_BASE/cni/bin"
sudo tar -xzf "$CACHE/$CNI_TAR" -C "$LIB_BASE/cni/bin" ./bridge ./host-local ./loopback

echo "[setup] resetting the work dir, copying the helpers and the starter..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$APP_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo install -d -m 755 "$RUN_BASE" "$LIB_BASE/containerd/root" "$LIB_BASE/containerd/etc"
cp "$CASE_DIR"/helpers/* "$STATE_DIR/"
cp "$CASE_DIR"/starter/* "$APP_DIR/"
(cd "$STATE_DIR" && sha256sum app.c entrypoint.c probe.go mkdind.py mkoci.py dns.py registry.py netprobe.py lab.py verify.py patch_config.py | awk '{print $1}' > helpers.sha)
cd "$WORK_DIR"

echo "[setup] the small static programs (the inner workload app, the entrypoint of the DIND image) and the probe (Go, standard library only)..."
gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
gcc -static -O2 -o "$STATE_DIR/entrypoint" "$STATE_DIR/entrypoint.c"
(cd "$STATE_DIR" && CGO_ENABLED=0 go build -o probe probe.go)

echo "[setup] the DIND image, made from the Docker engine of this machine (nothing is pulled from Docker Hub)..."
python3 "$STATE_DIR/mkdind.py" "$CASE_ID.local/dind:1" "$STATE_DIR/dind.tar" "$STATE_DIR/entrypoint" "$STATE_DIR/probe" > "$STATE_DIR/dind.json"
echo "  -> $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["manifest"], d["arch"], d["layer_size"] // 1048576, "MiB")' "$STATE_DIR/dind.json")"

echo "[setup] starting the private containerd (the containerd of this machine with its own root, state and socket)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd/root" "$RUN_BASE/state" "$SOCK" "$(id -u)" "$(id -g)" \
    | sudo tee "$LIB_BASE/containerd/etc/config.toml" >/dev/null
grep -q "$SOCK" "$LIB_BASE/containerd/etc/config.toml" || { echo "[setup] ERROR: could not set the socket in the containerd config"; exit 1; }
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$LIB_BASE/containerd/etc/config.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    [ -S "$SOCK" ] && sudo ctr -a "$SOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo ctr -a "$SOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the private containerd did not come up:"; sudo tail -10 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] building the program of the question (go build in $APP_DIR; the Go modules are downloaded on the first build)..."
(cd "$APP_DIR" && GOFLAGS=-mod=mod go build -o dind . > "$WORK_DIR/build.log" 2>&1) || { echo "[setup] ERROR: go build failed:"; tail -10 "$WORK_DIR/build.log"; exit 1; }

echo "[setup] the network of the lab (a node network with the DNS server and the registry, a pod network), the registry, the DNS server, the container of the engineer (made by the program)..."
python3 "$STATE_DIR/lab.py" up "$WORK_DIR" "$APP_DIR/dind" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. The container dind runs the DIND image in a network namespace of its own; the Docker inside it cannot pull from private-repo.local."
