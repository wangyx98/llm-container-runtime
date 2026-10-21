#!/bin/bash
set -e

CASE_ID="bench37420728"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                          # runc, the Go toolchain wrappers, the program (src/main.go -> bin/runner), the example bundle
RUN="/run/$CASE_ID"                              # runc's state directory (--root)
CACHE="/var/cache/$CASE_ID"                      # the downloaded and checked Docker package (runc) and Go toolchain, and the Go build cache (kept by cleanup.sh)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): truth.json, the service program, the bundle template
DOCKER_VERSION="20.10.24"                        # a Docker of the years of the question: its static package brings runc 1.1.5, the runc of this lab
GO_VERSION="1.24.7"
case "$(uname -m)" in
    x86_64|amd64)   DARCH="x86_64";  GO_ARCH="amd64"
        DOCKER_SHA="ab91092320a87691a1eaf0225b48585db9c69cff0ed4b0f569f744ff765515e3" ;;
    aarch64|arm64)  DARCH="aarch64"; GO_ARCH="arm64"
        DOCKER_SHA="aa73e8b07a6086d05a14729eb02c9b0810c81c1924c1908034e8de807a0d2fe7" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac
GO_ASSET="go$GO_VERSION.linux-$GO_ARCH.tar.gz"
GO_ROOT="$CACHE/go$GO_VERSION-$GO_ARCH"

echo "[setup] checking the tools: python3, curl, tar, gcc, sudo, sha256sum..."
for c in python3 curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
echo "  host: $(uname -m), kernel $(uname -r), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

echo "[setup] runc from the static Docker $DOCKER_VERSION package: from the cache $CACHE, else downloaded; the sha256 is checked either way..."
sudo install -d -m 755 "$CACHE"
PKG="docker-$DOCKER_VERSION-$DARCH.tgz"
if ! { [ -f "$CACHE/$PKG" ] && echo "$DOCKER_SHA  $CACHE/$PKG" | sha256sum -c --quiet - 2>/dev/null; }; then
    sudo rm -f "$CACHE/$PKG"
    curl -fsSL --retry 3 -o "$WORK_DIR/$PKG" "https://download.docker.com/linux/static/stable/$DARCH/docker-$DOCKER_VERSION.tgz" || { echo "[setup] ERROR: could not download the Docker package"; exit 1; }
    echo "$DOCKER_SHA  $WORK_DIR/$PKG" | sha256sum -c --quiet - || { echo "[setup] ERROR: $PKG does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$PKG" "$CACHE/$PKG"
    rm -f "$WORK_DIR/$PKG"
fi
tar -xzf "$CACHE/$PKG" -C "$WORK_DIR" docker/runc
sudo install -d -m 755 "$LIB" "$LIB/bin" "$LIB/src" "$RUN"
sudo install -d -m 700 "$RUN/state"
sudo install -m 755 -o root -g root "$WORK_DIR/docker/runc" "$LIB/bin/runc"
rm -rf "$WORK_DIR/docker"
echo "  $("$LIB/bin/runc" --version | head -1)"

echo "[setup] Go $GO_VERSION (the case's own toolchain, not the one of the machine): from the cache $CACHE, else downloaded and checked against the sha256 published by the Go project..."
if ! sudo test -x "$GO_ROOT/bin/go"; then
    if [ -n "${BENCH37420728_GO_TGZ:-}" ]; then cp "$BENCH37420728_GO_TGZ" "$WORK_DIR/gotgz"
    else
        for base in https://dl.google.com/go https://go.dev/dl; do
            curl -fsSL --retry 3 --max-time 900 -o "$WORK_DIR/gotgz" "$base/$GO_ASSET" && break
        done
        [ -s "$WORK_DIR/gotgz" ] || { echo "[setup] ERROR: could not download Go $GO_VERSION ($GO_ASSET from dl.google.com or go.dev)"; exit 1; }
        GO_SHA="${BENCH37420728_GO_SHA256:-}"
        [ -n "$GO_SHA" ] || GO_SHA="$(curl -fsSL --retry 3 --max-time 60 "https://dl.google.com/go/$GO_ASSET.sha256" | awk 'NR==1{print $1}')"
        echo "$GO_SHA" | grep -Eq '^[0-9a-f]{64}$' || { echo "[setup] ERROR: no sha256 for $GO_ASSET could be read (set BENCH37420728_GO_SHA256)"; exit 1; }
        echo "$GO_SHA  $WORK_DIR/gotgz" | sha256sum -c - >/dev/null 2>&1 || { echo "[setup] ERROR: the Go archive has the wrong sha256"; exit 1; }
    fi
    sudo rm -rf "$GO_ROOT.tmp"
    sudo mkdir -p "$GO_ROOT.tmp"
    sudo tar -xzf "$WORK_DIR/gotgz" -C "$GO_ROOT.tmp" --strip-components=1
    sudo chmod -R a+rX "$GO_ROOT.tmp"
    sudo mv "$GO_ROOT.tmp" "$GO_ROOT"
    rm -f "$WORK_DIR/gotgz"
fi
sudo test -x "$GO_ROOT/bin/go" || { echo "[setup] ERROR: the Go toolchain is not usable"; exit 1; }
sudo tee "$LIB/bin/build" >/dev/null <<EOF
#!/bin/sh
# build [SRC_DIR [OUT_FILE]]: compiles the Go module in SRC_DIR (default $LIB/src) with the Go $GO_VERSION of this lab into OUT_FILE (default $LIB/bin/runner); run it with sudo
SRC="\${1:-$LIB/src}"; OUT="\${2:-$LIB/bin/runner}"
GOROOT="$GO_ROOT"; GOTOOLCHAIN=local; GOCACHE="$CACHE/gocache"; GOPATH="$LIB/gopath"; GOFLAGS="-buildvcs=false"; CGO_ENABLED=0
export GOROOT GOTOOLCHAIN GOCACHE GOPATH GOFLAGS CGO_ENABLED
cd "\$SRC" && exec "\$GOROOT/bin/go" build -o "\$OUT" .
EOF
sudo chmod 755 "$LIB/bin/build"
echo "  $("$GO_ROOT/bin/go" version)"

echo "[setup] the service of the container (a static program: it answers 'pong nonce=N served=K' on /ctl/sock and writes 'svc nonce=N tick=K' to its stdout every second), the bundle template and the example bundle..."
cat > "$WORK_DIR/svc.c" <<'CEOF'
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* the long-running service of the container: a line on stdout every second, and a unix socket (/ctl/sock) that answers "pong" with its nonce */
int main(int argc, char **argv) {
    const char *nonce = argc > 1 ? argv[1] : "none";
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    int s = socket(AF_UNIX, SOCK_STREAM, 0), served = 0, tick = 0;
    char buf[160];
    strcpy(a.sun_path, "/ctl/sock");
    unlink(a.sun_path);
    if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 8) < 0) return 2;
    for (;;) {
        struct pollfd p = {.fd = s, .events = POLLIN};
        int n = poll(&p, 1, 1000);
        if (n > 0) {
            int c = accept(s, NULL, NULL);
            if (c >= 0) {
                int m = snprintf(buf, sizeof buf, "pong nonce=%s served=%d\n", nonce, ++served);
                if (write(c, buf, m) < 0) {}
                close(c);
            }
        } else if (n == 0) {
            int m = snprintf(buf, sizeof buf, "svc nonce=%s tick=%d\n", nonce, ++tick);
            if (write(1, buf, m) < 0 && errno != EINTR) return 3;
        }
    }
}
CEOF
gcc -static -Os -s -w -o "$WORK_DIR/svc" "$WORK_DIR/svc.c"
sudo install -m 755 "$WORK_DIR/svc" "$STATE_DIR/svc"
rm -f "$WORK_DIR/svc" "$WORK_DIR/svc.c"
mkdir -p "$WORK_DIR/spec"
(cd "$WORK_DIR/spec" && "$LIB/bin/runc" spec)
sudo python3 - "$WORK_DIR/spec/config.json" "$STATE_DIR" "$LIB/example" <<'PYEOF'
import json
import os
import shutil
import sys

spec, state, example = sys.argv[1:4]
c = json.load(open(spec))
c["process"]["terminal"] = False
c["process"]["args"] = ["/svc", "example"]
c["root"]["readonly"] = True
c["mounts"].append({"destination": "/ctl", "type": "bind", "source": "/ctl", "options": ["rbind", "rw"]})
c["linux"]["cgroupsPath"] = "bench37420728/example"
json.dump(c, open(state + "/config.json", "w"), indent=1)
os.makedirs(example + "/rootfs/ctl")
os.makedirs(example + "/ctl")
shutil.copy(state + "/svc", example + "/rootfs/svc")
c["mounts"][-1]["source"] = example + "/ctl"
json.dump(c, open(example + "/config.json", "w"), indent=1)
PYEOF
rm -rf "$WORK_DIR/spec"

echo "[setup] the Go program (src/main.go, module bench37420728/runner) as the question has it, built into bin/runner..."
sudo tee "$LIB/src/main.go" >/dev/null <<'GOEOF'
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"time"
)

// runner RUNC ROOT BUNDLE ID [HOLD_SECONDS]: starts the container ID of BUNDLE detached with RUNC (state directory ROOT) and says how long that took;
// with HOLD_SECONDS it then stays alive that long (a test driver that goes on to do other work).
func main() {
	if len(os.Args) < 5 {
		fmt.Fprintln(os.Stderr, "usage: runner RUNC ROOT BUNDLE ID [HOLD_SECONDS]")
		os.Exit(2)
	}
	runc, root, bundle, id := os.Args[1], os.Args[2], os.Args[3], os.Args[4]
	command := exec.Command(runc, "--root", root, "run", "-d", id)
	command.Dir = bundle
	start := time.Now()
	r, err := command.CombinedOutput()
	duration := int64(time.Since(start) / time.Millisecond)
	fmt.Println(duration)
	fmt.Println(err)
	fmt.Println(string(r))
	if err != nil {
		os.Exit(1)
	}
	if len(os.Args) > 5 {
		if hold, e := strconv.Atoi(os.Args[5]); e == nil {
			time.Sleep(time.Duration(hold) * time.Second)
		}
	}
}
GOEOF
printf 'module bench37420728/runner\n\ngo 1.18\n' | sudo tee "$LIB/src/go.mod" >/dev/null
sudo "$LIB/bin/build"
echo "  $(sudo "$LIB/bin/runner" 2>&1 | head -1)"

echo "[setup] recording what is true..."
sudo python3 - "$STATE_DIR" "$LIB" <<'PYEOF'
import hashlib
import json
import subprocess
import sys

state, lib = sys.argv[1:3]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
json.dump({
    "runc_sha": sha(lib + "/bin/runc"),
    "runc_version": subprocess.run([lib + "/bin/runc", "--version"], capture_output=True, text=True).stdout.splitlines()[0],
    "svc_sha": sha(state + "/svc"),
    "runner_src_sha": sha(lib + "/src/main.go"),
    "runner_sha": sha(lib + "/bin/runner"),
    "build_sha": sha(lib + "/bin/build"),
}, open(state + "/truth.json", "w"), indent=1)
PYEOF
echo "[setup] done: runc $("$LIB/bin/runc" --version | head -1 | awk '{print $3}'), the program in $LIB/src/main.go (build: sudo $LIB/bin/build), example bundle $LIB/example"
