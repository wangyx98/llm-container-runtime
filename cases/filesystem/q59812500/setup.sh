#!/bin/bash
set -e

CASE_ID="bench59812500"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the lab: the daemon's source, the rootfs, the Go toolchain (a link into the cache)
CACHE="/var/cache/$CASE_ID"                  # the Go release (kept by cleanup)
ROOTFS="$LIB/rootfs"                         # the asker's /home/utsav
DAEMON="$LIB/daemon"                         # the asker's program
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
GO_VERSION="go1.13.5"

case "$(uname -m)" in
    x86_64|amd64)  GOARCH="amd64" ;;
    aarch64|arm64) GOARCH="arm64" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, tar, sudo, sha256sum, ldd..."
for c in python3 curl tar sudo sha256sum ldd; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
echo "  host: $(uname -m), kernel $(uname -r), user $(id -un)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR/ctl"
sudo chown -R root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$CACHE"

# The asker's Go 1.13.5. The release is taken from go.dev and checked against the sha256 that go.dev itself lists; it is extracted once and kept in the cache. BENCH_GO_ROOT=<GOROOT of a Go
# installation> uses that one instead (no download; for a machine without access to go.dev); the version actually used is recorded and shown.
if [ -n "${BENCH_GO_ROOT:-}" ]; then
    [ -x "$BENCH_GO_ROOT/bin/go" ] || { echo "[setup] ERROR: BENCH_GO_ROOT has no bin/go"; exit 1; }
    GO_ROOT="$BENCH_GO_ROOT"
    echo "  Go: BENCH_GO_ROOT=$GO_ROOT (not $GO_VERSION!)"
else
    GO_ROOT="$CACHE/$GO_VERSION-$GOARCH"
    if [ ! -x "$GO_ROOT/bin/go" ]; then
        TGZ="$GO_VERSION.linux-$GOARCH.tar.gz"
        echo "[setup] fetching $TGZ from go.dev (about 100 MB)..."
        SHA=$(curl -fsSL --retry 3 --max-time 120 "https://go.dev/dl/?mode=json&include=all" | python3 -c '
import json, sys
for rel in json.load(sys.stdin):
    for f in rel["files"]:
        if f["filename"] == sys.argv[1]:
            print(f["sha256"])
' "$TGZ") || true
        [ -n "$SHA" ] || { echo "[setup] ERROR: go.dev does not list the sha256 of $TGZ"; exit 1; }
        curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$TGZ" "https://go.dev/dl/$TGZ" || { echo "[setup] ERROR: could not download $TGZ"; exit 1; }
        echo "$SHA  $WORK_DIR/$TGZ" | sha256sum -c --quiet - || { echo "[setup] ERROR: $TGZ does not match its sha256"; exit 1; }
        mkdir -p "$WORK_DIR/goext"
        tar -C "$WORK_DIR/goext" -xzf "$WORK_DIR/$TGZ"
        sudo rm -rf "$GO_ROOT"
        sudo mv "$WORK_DIR/goext/go" "$GO_ROOT"
        rm -rf "$WORK_DIR/goext" "$WORK_DIR/$TGZ"
    fi
fi
sudo ln -sfn "$GO_ROOT" "$LIB/go"
GO_REPORT=$("$LIB/go/bin/go" version) || { echo "[setup] ERROR: the Go toolchain does not run"; exit 1; }
echo "  $GO_REPORT"
echo "$GO_REPORT" | sudo tee "$STATE_DIR/go.version" >/dev/null

echo "[setup] making the rootfs (/bin/bash, ls, cat of this machine with their libraries) and its unique marker..."
sudo install -d -m 755 "$ROOTFS" "$ROOTFS/bin"
for b in bash ls cat; do
    p=$(readlink -f "$(command -v "$b")")
    sudo install -m 755 "$p" "$ROOTFS/bin/$b"
    for l in $(ldd "$p" | grep -o '/[^ ]*'); do
        sudo install -D -m 755 "$(readlink -f "$l")" "$ROOTFS$l"
    done
done
MARK=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
echo "$MARK" | sudo tee "$ROOTFS/marker" >/dev/null
sudo chmod 644 "$ROOTFS/marker"
echo "$MARK" | sudo tee "$STATE_DIR/marker" >/dev/null
python3 -c 'import secrets; print(secrets.token_hex(12))' | sudo tee "$LIB/host-marker" >/dev/null     # only on the host: not in the rootfs

echo "[setup] writing the asker's daemon (source, module file) and building it..."
sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 755 "$DAEMON"   # the user edits and builds here
cat > "$DAEMON/go.mod" <<'GOMOD'
module daemon

go 1.13
GOMOD
cat > "$DAEMON/main.go" <<'GOSRC'
package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

// the asker's /home/utsav
const rootfs = "/var/lib/bench59812500/rootfs"

func main() {
	switch os.Args[1] {
	case "run":
		run()
	case "child":
		child()
	default:
		panic("Too less arguments")
	}
}

func run() {
	fmt.Printf("Running: %v\n", os.Args[2:])

	cmd := exec.Command("/proc/self/exe", append([]string{"child"}, os.Args[2:]...)...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS,
	}

	cnr(cmd.Run())
}

func child() {
	cmd := exec.Command(os.Args[2], os.Args[3:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS,
		Chroot:     rootfs,
	}

	syscall.Sethostname([]byte("container"))

	cnr(cmd.Run())
}

func cnr(err error) { //Check and Run
	if err != nil {
		panic(err)
	}
}
GOSRC
# the code as posted in the question (Chroot and Chdir in the process itself), only the path is the lab's: a control for the precondition, kept where the solution cannot reach it
sudo tee "$STATE_DIR/ctl/posted.go" >/dev/null <<'GOSRC'
package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

func main() {
	switch os.Args[1] {
	case "run":
		run()
	case "child":
		child()
	default:
		panic("Too less arguments")
	}
}

func run() {
	fmt.Printf("Running: %v\n", os.Args[2:])

	cmd := exec.Command("/proc/self/exe", append([]string{"child"}, os.Args[2:]...)...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS,
	}

	cnr(cmd.Run())
}

func child() {
	cmd := exec.Command(os.Args[2], os.Args[3:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS,
	}

	syscall.Sethostname([]byte("container"))
	syscall.Chroot("/var/lib/bench59812500/rootfs")
	syscall.Chdir("/")

	cnr(cmd.Run())
}

func cnr(err error) { //Check and Run
	if err != nil {
		panic(err)
	}
}
GOSRC
(cd "$DAEMON" && env -i PATH=/usr/bin:/bin HOME="$HOME" CGO_ENABLED=0 GOFLAGS= GOPROXY=off GO111MODULE=on "$LIB/go/bin/go" build -o daemon .) || { echo "[setup] ERROR: the daemon does not build"; exit 1; }

echo "[setup] recording what is true (the oracle and the precondition check it)..."
sudo sh -c "cd / && find '$ROOTFS' -type f -print0 | sort -z | xargs -0 sha256sum > '$STATE_DIR/rootfs.sha' && find '$ROOTFS' | sort > '$STATE_DIR/rootfs.list'"
sudo sh -c "sha256sum '$DAEMON/main.go' '$DAEMON/go.mod' '$LIB/host-marker' > '$STATE_DIR/lab.sha'"
sudo sh -c "date +%s > '$STATE_DIR/ready'"
echo "[setup] done: daemon $DAEMON (sudo $DAEMON/daemon run /bin/bash), rootfs $ROOTFS, $GO_REPORT"
