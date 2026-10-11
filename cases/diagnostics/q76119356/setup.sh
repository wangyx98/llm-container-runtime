#!/bin/bash
set -e

CASE_ID="bench76119356"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files, logs and runtime state of the endpoints
LIB_BASE="/var/lib/$CASE_ID"          # their containerd roots, Docker data-roots and configs (not in /run: it is mounted noexec on many hosts)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
APP_DIR="$WORK_DIR/app"               # the Go program (the one the solution changes)
GO_MIN="1.21"

echo "[setup] checking containerd, ctr, runc, dockerd, the docker CLI, python3 and Go are installed (the runtime under test, the usual tools and the toolchain)..."
command -v go >/dev/null || {
    echo "[setup] ERROR: go not found in PATH. This case compiles a Go program and needs Go >= 1.21 (the distro package is usually older)."
    echo "[setup]   Install the official toolchain, then make it visible to sudo and to 'bash -c' too, not only to login shells, for example (arm64 shown):"
    echo "[setup]     curl -fsSL https://go.dev/dl/go1.23.4.linux-arm64.tar.gz | sudo tar -C /usr/local -xzf -"
    echo "[setup]     sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go && sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt"
    exit 1
}
for b in containerd ctr runc dockerd docker python3 go; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found (this case compiles a Go program: it needs Go >= $GO_MIN)"; exit 1; }
done
dockerd --version
GOV=$(go env GOVERSION)
echo "  -> $GOV"
python3 - "$GOV" "$GO_MIN" <<'PYEOF' || { echo "[setup] ERROR: Go is older than $GO_MIN"; exit 1; }
import re
import sys

have = [int(x) for x in re.match(r"go(\d+)\.(\d+)", sys.argv[1]).groups()]
need = [int(x) for x in sys.argv[2].split(".")]
sys.exit(0 if have >= need else 1)
PYEOF

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$APP_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE"
cp "$CASE_DIR"/helpers/* "$STATE_DIR/"
cp "$CASE_DIR"/starter/* "$APP_DIR/"
sha256sum "$STATE_DIR"/lib.sh "$STATE_DIR"/patch_config.py | awk '{print $1}' > "$STATE_DIR/helpers.sha"
cd "$WORK_DIR"
. "$STATE_DIR/lib.sh"

echo "[setup] starting two isolated Docker endpoints, each a private containerd and a private dockerd with its own socket and data, no bridge or"
echo "[setup] iptables (nothing here touches the host's networking). Their runtime configuration differs: a: default runtime bench-a-default (and bench-a-extra);"
echo "[setup] b: Docker's own default, runc (and bench-b-extra)..."
start_endpoint a bench-a-default bench-a-extra
echo "  -> endpoint a: $(endpoint_sock a)"
start_endpoint b runc bench-b-extra
echo "  -> endpoint b: $(endpoint_sock b)"

echo "[setup] recording what each daemon reports (the truth: default runtime and the names of its runtimes, from its own API)..."
for e in a b; do
    docker -H "unix://$(endpoint_sock $e)" info --format '{{.DefaultRuntime}}|{{json .Runtimes}}' | python3 -c '
import json, sys
d, r = sys.stdin.read().strip().split("|", 1)
print(json.dumps({"default_runtime": d, "runtimes": sorted(json.loads(r))}))' > "$STATE_DIR/$e.truth"
    echo "  -> $e: $(cat "$STATE_DIR/$e.truth")"
done

echo "[setup] building the Go program (the starter: it reads the dockerd process of this machine; it needs no module)..."
cd "$APP_DIR"
GOFLAGS=-mod=mod go build -o rtinfo . 2>&1 | tail -5
[ -x "$APP_DIR/rtinfo" ] || { echo "[setup] ERROR: the starter does not build"; exit 1; }
cd "$WORK_DIR"
echo "  -> $APP_DIR/rtinfo built from $APP_DIR/main.go"

echo "[setup] done. Two Docker endpoints ($(endpoint_sock a) and $(endpoint_sock b)) with different default runtimes; the program in $APP_DIR does not look at the endpoint."
