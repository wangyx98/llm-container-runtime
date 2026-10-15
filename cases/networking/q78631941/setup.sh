#!/bin/bash
set -e

CASE_ID="bench78631941"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files and state of the private containerd and of the SOCI snapshotter
LIB_BASE="/var/lib/$CASE_ID"          # roots, binaries, the registry's blobs, the CNI plugins (not in /run: it is mounted noexec on many hosts)
CACHE="/var/cache/$CASE_ID"           # the downloaded CNI plugins and SOCI release (kept by cleanup.sh; checked against their checksums at every setup)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
APP_DIR="$WORK_DIR/app"               # the Go program of the question (the one the solution may change)
SOCK="$RUN_BASE/containerd.sock"
CNI_VERSION="v1.5.1"                  # containernetworking/plugins: ptp, host-local and loopback join the registry's network namespace to the host
SOCI_VERSION="0.16.1"                 # awslabs/soci-snapshotter: its resolver configuration also governs where the index and the ztocs are fetched from (older releases: HTTPS for every host but localhost)
GO_MIN="1.23"                         # what the pinned SDK (containerd v2.0.5) asks of the Go toolchain

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

echo "[setup] checking the tools: containerd, ctr, runc, go, gcc, nsenter, unshare, python3, curl, FUSE..."
for b in containerd ctr runc containerd-shim-runc-v2 go gcc nsenter unshare tar curl sha256sum python3 sudo; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
grep -qw fuse /proc/filesystems || sudo modprobe fuse 2>/dev/null || true
[ -c /dev/fuse ] && grep -qw fuse /proc/filesystems || { echo "[setup] ERROR: no FUSE in this kernel (/dev/fuse, the file system type fuse): the SOCI snapshotter mounts layers through FUSE"; exit 1; }
GOV=$(go env GOVERSION)
python3 - "$GOV" "$GO_MIN" <<'PYEOF' || { echo "[setup] ERROR: Go ($GOV) is older than $GO_MIN"; exit 1; }
import re
import sys

have = [int(x) for x in re.match(r"go(\d+)\.(\d+)", sys.argv[1]).groups()]
need = [int(x) for x in sys.argv[2].split(".")]
sys.exit(0 if have >= need else 1)
PYEOF
containerd --version | head -1
case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1;; esac

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

# fetch FILE URL : download to the cache and check against the checksum published next to it (URL.sha256 or URL.sha256sum), unless the cached copy already matches the recorded one
fetch() {
    local file="$1" url="$2" sumurl="$3" want tmp
    want=$(sudo cat "$CACHE/$file.sha256" 2>/dev/null || true)
    if [ "${#want}" = 64 ] && echo "$want  $CACHE/$file" | sudo sha256sum -c --status 2>/dev/null; then return 0; fi
    want=$(curl -fsSL --retry 3 --max-time 60 "$sumurl" | awk '{print $1}')
    [ "${#want}" = 64 ] || { echo "[setup] ERROR: no checksum for $file"; exit 1; }
    sudo rm -f "$CACHE/$file"
    tmp=$(mktemp)
    curl -fsSL --retry 3 --max-time 300 -o "$tmp" "$url" || { rm -f "$tmp"; echo "[setup] ERROR: could not download $url"; exit 1; }
    sudo install -m 644 "$tmp" "$CACHE/$file"; rm -f "$tmp"
    echo "$want  $CACHE/$file" | sudo sha256sum -c --status || { echo "[setup] ERROR: the checksum of $file is wrong"; sudo rm -f "$CACHE/$file"; exit 1; }
    echo "$want" | sudo tee "$CACHE/$file.sha256" >/dev/null
}

echo "[setup] the CNI plugins $CNI_VERSION and the SOCI snapshotter v$SOCI_VERSION (checked against the published checksums, cached in $CACHE)..."
sudo install -d -m 755 "$CACHE"
CNI_TAR="cni-plugins-linux-$ARCH-$CNI_VERSION.tgz"
CNI_URL="https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/$CNI_TAR"
fetch "$CNI_TAR" "$CNI_URL" "$CNI_URL.sha256"
SOCI_TAR="soci-snapshotter-$SOCI_VERSION-linux-$ARCH.tar.gz"
SOCI_URL="https://github.com/awslabs/soci-snapshotter/releases/download/v$SOCI_VERSION/$SOCI_TAR"
fetch "$SOCI_TAR" "$SOCI_URL" "$SOCI_URL.sha256sum"
sudo install -d -m 755 "$LIB_BASE" "$LIB_BASE/cni/bin" "$LIB_BASE/bin" "$LIB_BASE/soci" "$LIB_BASE/containerd/root" "$LIB_BASE/containerd/etc" "$RUN_BASE"
sudo tar -xzf "$CACHE/$CNI_TAR" -C "$LIB_BASE/cni/bin" ./ptp ./host-local ./loopback
sudo tar -xzf "$CACHE/$SOCI_TAR" -C "$LIB_BASE/bin" soci soci-snapshotter-grpc
sudo chmod 755 "$LIB_BASE/bin/soci" "$LIB_BASE/bin/soci-snapshotter-grpc"
"$LIB_BASE/bin/soci-snapshotter-grpc" --version

echo "[setup] resetting the work dir, copying the helpers and the starter..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$APP_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
cp "$CASE_DIR"/helpers/* "$STATE_DIR/"
cp "$CASE_DIR"/starter/* "$APP_DIR/"
(cd "$STATE_DIR" && sha256sum reader.c mkimage.py registry.py lab.py verify.py patch_config.py soci-service | awk '{print $1}' > helpers.sha)
sudo install -m 755 "$STATE_DIR/soci-service" "$LIB_BASE/bin/soci-service"
cd "$WORK_DIR"

echo "[setup] the workload of the images (a small static program: sleeps, or prints the sha256 of a file it reads)..."
gcc -static -O2 -o "$STATE_DIR/reader" "$STATE_DIR/reader.c"

echo "[setup] building the program of the question (go build in $APP_DIR; the Go modules are downloaded on the first build) and the lab's own copy of it..."
(cd "$APP_DIR" && GOFLAGS=-mod=mod go build -o lazyrun . > "$WORK_DIR/build.log" 2>&1) || { echo "[setup] ERROR: go build failed:"; tail -10 "$WORK_DIR/build.log"; exit 1; }
mkdir -p "$STATE_DIR/ctl"
cp "$CASE_DIR"/starter/* "$STATE_DIR/ctl/"
(cd "$STATE_DIR/ctl" && GOFLAGS=-mod=mod go build -o "$STATE_DIR/lazyrun-ctl" . > "$WORK_DIR/build-ctl.log" 2>&1) || { echo "[setup] ERROR: go build (the lab's copy) failed:"; tail -10 "$WORK_DIR/build-ctl.log"; exit 1; }

echo "[setup] the configuration of the SOCI snapshotter and of the private containerd (own root, state and socket; the proxy plugin soci talks to the snapshotter)..."
sudo tee "$LIB_BASE/soci/config.toml" >/dev/null <<EOT
# Configuration of the SOCI snapshotter (soci-snapshotter-grpc --config). It is read when the snapshotter starts:
# after a change, restart it with: sudo $LIB_BASE/bin/soci-service restart

# the rest of a layer is not fetched in the background: only what is read is fetched
[background_fetch]
disable = true
EOT
sudo chmod 644 "$LIB_BASE/soci/config.toml"
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd/root" "$RUN_BASE/state" "$SOCK" "$(id -u)" "$(id -g)" \
    | sudo tee "$LIB_BASE/containerd/etc/config.toml" >/dev/null
grep -q "$SOCK" "$LIB_BASE/containerd/etc/config.toml" || { echo "[setup] ERROR: could not set the socket in the containerd config"; exit 1; }
sudo tee -a "$LIB_BASE/containerd/etc/config.toml" >/dev/null <<EOT

[proxy_plugins]
  [proxy_plugins.soci]
    type = "snapshot"
    address = "$RUN_BASE/soci.sock"
EOT

echo "[setup] starting the SOCI snapshotter and the private containerd..."
sudo "$LIB_BASE/bin/soci-service" start
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$LIB_BASE/containerd/etc/config.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    [ -S "$SOCK" ] && sudo ctr -a "$SOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo ctr -a "$SOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the private containerd did not come up:"; sudo tail -10 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }
sudo ctr -a "$SOCK" plugins ls 2>/dev/null | grep -q "soci.*ok" || { echo "[setup] ERROR: containerd does not know the proxy snapshotter soci:"; sudo ctr -a "$SOCK" plugins ls 2>/dev/null | grep -i "soci\|snapshot" | head; exit 1; }

echo "[setup] the registry (plain HTTP, in a network namespace of its own that the host reaches through a veth pair), the image app:seed (one layer of ~48 MiB with a SOCI index) and the container made by the program..."
python3 "$STATE_DIR/lab.py" up "$WORK_DIR" "$APP_DIR/lazyrun" || { echo "[setup] ERROR: the lab did not come up"; exit 1; }

echo "[setup] done. The container lazy runs from app:seed; the snapshotter did not lazy-load its layer."
