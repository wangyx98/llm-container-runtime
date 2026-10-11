#!/bin/bash
set -e

CASE_ID="bench78432931"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and log of the private containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root and config (not in /run: it is mounted noexec on many hosts)
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
APP_DIR="$WORK_DIR/app"               # the Go program of the question (the one the solution changes)
REG_PORT=43293
REG_ADDR="127.0.0.1:$REG_PORT"
NS="k8s.io"                           # the containerd namespace of the question
APP_REF="$REG_ADDR/bench/app:1"       # the image the solution may pull while it tries things out
TINY_REF="$REG_ADDR/bench/tiny:1"     # a one-layer image for the precondition's silent pull

CTR_T="sudo ctr -a $T_SOCK"
GO_MIN="1.23"                          # what the pinned SDK (containerd v2.0.5) asks of the Go toolchain

echo "[setup] checking containerd, ctr, python3 and Go are installed (the runtime under test, the usual tools, and the toolchain of the Go client)..."
for b in containerd ctr python3 go; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found (this case compiles a Go program: it needs Go >= $GO_MIN)"; exit 1; }
done
containerd --version
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
mkdir -p "$STATE_DIR/registry" "$APP_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$T_STATE" "$T_ROOT" "$(dirname "$T_CFG")"
cp "$CASE_DIR"/helpers/*.py "$STATE_DIR/"
cp "$CASE_DIR"/starter/* "$APP_DIR/"
sha256sum "$STATE_DIR"/registry.py "$STATE_DIR"/mkimage.py "$STATE_DIR"/patch_config.py | awk '{print $1}' > "$STATE_DIR/helpers.sha"
cd "$WORK_DIR"

echo "[setup] writing the containerd config (the default one for the installed version, in its own root, state and socket; the socket is the user's, so the Go program needs no sudo)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$T_ROOT" "$T_STATE" "$T_SOCK" "$(id -u)" "$(id -g)" \
    | sudo tee "$T_CFG" >/dev/null
grep -q "$T_SOCK" "$T_CFG" || { echo "[setup] ERROR: could not set the socket in the containerd config"; exit 1; }
sudo sha256sum "$T_CFG" | awk '{print $1}' > "$STATE_DIR/config.sha"

echo "[setup] starting the private containerd (a plain 'containerd --config <file>', its pid in a file)..."
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$T_CFG" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    [ -S "$T_SOCK" ] && $CTR_T version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $CTR_T version >/dev/null 2>&1; then
    echo "[setup] ERROR: the private containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
P=$(sudo cat "$RUN_BASE/containerd.pid")
echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
echo "  -> containerd up on $T_SOCK, namespace $NS is the one of the question"

echo "[setup] starting the registry: plain HTTP on $REG_ADDR, every layer served at a limited rate (so that a pull takes seconds, as a real one does)..."
python3 - "$REG_PORT" <<'PYEOF' || { echo "[setup] ERROR: port $REG_PORT is in use"; exit 1; }
import socket
import sys

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)   # as the registry does: a port in TIME_WAIT is free
s.bind(("127.0.0.1", int(sys.argv[1])))
PYEOF
setsid -f bash -c 'echo $$ > "$1"; exec python3 "$2" "$3" "$4" >"$5" 2>&1 </dev/null' \
    _ "$STATE_DIR/registry.pid" "$STATE_DIR/registry.py" "$STATE_DIR/registry" "$REG_PORT" "$STATE_DIR/registry.log" </dev/null >/dev/null 2>&1
reg_get() {
    python3 - "$1" <<'PYEOF'
import sys
import urllib.request

print(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(sys.argv[1], timeout=5).status)
PYEOF
}
for _ in $(seq 1 40); do
    reg_get "http://$REG_ADDR/v2/" >/dev/null 2>&1 && break
    sleep 0.25
done
reg_get "http://$REG_ADDR/v2/" >/dev/null 2>&1 || { echo "[setup] ERROR: the registry does not answer"; exit 1; }
P=$(cat "$STATE_DIR/registry.pid")
echo "$P $(awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/registry.id"

echo "[setup] making the images (random layers, so nothing can be written down beforehand)..."
python3 - "$STATE_DIR" <<'PYEOF'
import json
import random
import subprocess
import sys

state = sys.argv[1]
MiB = 1024 * 1024
r = random.SystemRandom()


def mk(repo, tag, layers):
    out = subprocess.check_output(["python3", state + "/mkimage.py", state + "/registry", repo, tag, "--layers",
                                   ",".join("%d:%.1f" % l for l in layers)])
    return json.loads(out)


# three layers of different sizes (a pull reports a blob's bytes in steps of 1 MiB: they have to be several MiB), served in 8-9 s, 6-8 s and 6-8 s
app = mk("bench/app", "1", [(r.randint(5 * MiB, 6 * MiB), r.uniform(8.0, 9.0)),
                            (r.randint(int(4.3 * MiB), 5 * MiB), r.uniform(6.0, 8.0)),
                            (r.randint(int(4.3 * MiB), 5 * MiB), r.uniform(6.0, 8.0))])
tiny = mk("bench/tiny", "1", [(64 * 1024, 0.2)])
json.dump(app, open(state + "/app.json", "w"))
json.dump(tiny, open(state + "/tiny.json", "w"))
print("  -> bench/app:1 %s, layers %s (%.1f MiB)" % (app["manifest"]["digest"][:19],
      " + ".join("%.1f MiB" % (l["size"] / MiB) for l in app["layers"]), sum(l["size"] for l in app["layers"]) / MiB))
PYEOF

echo "[setup] compiling the program of the question (the Go client, pinned: containerd v2.0.5; modules are downloaded the first time)..."
cd "$APP_DIR"
if ! GOFLAGS=-mod=mod go build -o pull . > "$WORK_DIR/build.log" 2>&1; then
    echo "[setup] ERROR: the starter program does not build (Go needs the module proxy the first time); the last lines of the build:"
    tail -15 "$WORK_DIR/build.log"
    exit 1
fi
rm -f "$WORK_DIR/build.log"
echo "  -> $APP_DIR/pull built from $APP_DIR/main.go"
cd "$WORK_DIR"

echo "[setup] done. A private containerd ($T_SOCK, namespace $NS) and a registry ($REG_ADDR) holding $APP_REF; the program of the question is in $APP_DIR (silent)."
