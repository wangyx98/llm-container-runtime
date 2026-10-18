#!/bin/bash
set -e

CASE_ID="bench63457756"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files and logs of the engineer's containerd and dockerd
LIB_BASE="/var/lib/$CASE_ID"          # bin (stack, docker), opt (link to the installed containerd package), packages (the package cache), etc, data of both daemons
CACHE="/var/cache/$CASE_ID"           # Go 1.15 and the two compiled containerd packages (kept by cleanup.sh)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE="localhost/bench63457756/web:1"

# containerd 1.4.0 of Arch Linux: the same source (tag v1.4.0), two builds of the PKGBUILD
#   1.4.0-1: make EXTRA_LDFLAGS="-linkmode external" ...      (the package of the question)
#   1.4.0-2: make ...                                         (FS#67621 "Remove linkmode=external"; the fix)
# both with Go 1.15 and GOFLAGS="-buildmode=pie -trimpath -mod=readonly -modcacherw" (the Arch package of that time was x86_64 only and cannot run on
# this machine: the packages are compiled here from the source with exactly these two recipes)
CTD_TAG="v1.4.0"; CTD_COMMIT="09814d48d50816305a8e6c1a4ae3e2bcc4ba725a"
CTD_REV1="be75852b8d7849474a20192f9ed1bf34fdd454f1"        # the REVISION string of the PKGBUILD 1.4.0-1 (a label inside the binary, not the source)
GO_VERSION="1.15"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the architecture, docker, dockerd, runc, python3 and sha256sum of this machine..."
# the defect exists only on x86_64 (the Arch packages are x86_64 only, and the shim of the 1.4.0-1 recipe starts fine on aarch64): not runnable elsewhere
case "$(uname -m)" in
    x86_64) GOARCH_NAME=amd64 ;;
    *) echo "[setup] NOT APPLICABLE: q63457756 reproduces only on x86_64 (the shim built with the recipe of Arch containerd 1.4.0-1 aborts at start only there); exclude this case on $(uname -m)."; exit 1 ;;
esac
for b in docker dockerd runc python3 sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
DOCKER_BIN="$(command -v docker)"; DOCKERD_BIN="$(command -v dockerd)"; RUNC_BIN="$(command -v runc)"
echo "  host: docker client $($DOCKER_BIN --version | head -1)"
echo "  host: dockerd $($DOCKERD_BIN --version | head -1)"
echo "  host: $(runc --version | head -1), $(uname -m), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$CACHE"
cd "$WORK_DIR"

# ---- the two packages. Compiled once from the pinned commit, kept in the cache; BENCH63457756_BUILDS_DIR names a directory that already has
# containerd-1.4.0-1 and containerd-1.4.0-2 (no compiling). A package in the cache that was not built with this Go is thrown away.
if [ -z "${BENCH63457756_BUILDS_DIR:-}" ] && [ "$(sudo cat "$CACHE/go" 2>/dev/null)" != "go$GO_VERSION|$CTD_COMMIT" ]; then
    sudo rm -rf "$CACHE/containerd-1.4.0-1" "$CACHE/containerd-1.4.0-2" "$CACHE/go"
fi
need=""
for p in containerd-1.4.0-1 containerd-1.4.0-2; do
    if [ -n "${BENCH63457756_BUILDS_DIR:-}" ] && [ -d "$BENCH63457756_BUILDS_DIR/$p" ]; then
        sudo rm -rf "$CACHE/$p"; sudo mkdir -p "$CACHE/$p"; sudo cp -a "$BENCH63457756_BUILDS_DIR/$p/." "$CACHE/$p/"
    fi
    sudo test -x "$CACHE/$p/containerd-shim-runc-v2" || need="$need $p"
done
if [ -n "$need" ]; then
    echo "[setup] compiling what is not cached yet:$need (first run only; several minutes)..."
    for b in git gcc make curl; do command -v "$b" >/dev/null || NEED_APT=1; done
    if [ -n "${NEED_APT:-}" ]; then
        sudo -E apt-get update -qq
        sudo -E apt-get install -y -qq "${APT_OPTS[@]}" git gcc make curl libc6-dev
    fi
    GOROOT_DIR="$CACHE/go$GO_VERSION"
    if ! sudo test -x "$GOROOT_DIR/bin/go"; then
        echo "[setup] fetching the Go $GO_VERSION toolchain (sha256 checked against the list of go.dev)..."
        GO_TAR="go$GO_VERSION.linux-$GOARCH_NAME.tar.gz"
        mkdir -p "$WORK_DIR/dl"
        curl -fsSL --retry 3 -o "$WORK_DIR/dl/$GO_TAR" "https://go.dev/dl/$GO_TAR" \
            || { echo "[setup] ERROR: could not download https://go.dev/dl/$GO_TAR"; exit 1; }
        GO_SUM="$(curl -fsSL --retry 3 "https://go.dev/dl/?mode=json&include=all" \
            | python3 -c 'import json,sys; f=sys.argv[1]; print(next(x["sha256"] for r in json.load(sys.stdin) for x in r["files"] if x["filename"]==f))' "$GO_TAR")" \
            || { echo "[setup] ERROR: no sha256 for $GO_TAR in the list of go.dev"; exit 1; }
        echo "$GO_SUM  $WORK_DIR/dl/$GO_TAR" | sha256sum -c --status || { echo "[setup] ERROR: sha256 of $GO_TAR does not match"; exit 1; }
        sudo mkdir -p "$GOROOT_DIR"
        sudo tar -xzf "$WORK_DIR/dl/$GO_TAR" -C "$GOROOT_DIR" --strip-components=1
        rm -rf "$WORK_DIR/dl"
    fi
    "$GOROOT_DIR/bin/go" version
    mkdir -p "$WORK_DIR/gopath/src/github.com/containerd"
    SRC="$WORK_DIR/gopath/src/github.com/containerd/containerd"
    git clone --quiet --depth 1 --branch "$CTD_TAG" https://github.com/containerd/containerd.git "$SRC" >/dev/null 2>&1 \
        || { echo "[setup] ERROR: could not clone containerd $CTD_TAG"; exit 1; }
    [ "$(git -C "$SRC" rev-parse HEAD)" = "$CTD_COMMIT" ] || { echo "[setup] ERROR: containerd $CTD_TAG is not the pinned commit $CTD_COMMIT"; exit 1; }
    build_pkg() {       # $1 = package, $2 = REVISION label, the rest = extra arguments of make
        local pkg="$1" rev="$2"; shift 2
        sudo test -x "$CACHE/$pkg/containerd-shim-runc-v2" && return 0
        ( cd "$SRC" && rm -rf bin && env PATH="$GOROOT_DIR/bin:$PATH" GOROOT="$GOROOT_DIR" GOPATH="$WORK_DIR/gopath" GO111MODULE=auto GOCACHE="$WORK_DIR/gocache" \
            CGO_CFLAGS="-O2 -pipe -fno-plt -fstack-protector-strong" CGO_CPPFLAGS="-D_FORTIFY_SOURCE=2" CGO_CXXFLAGS="-O2 -pipe -fno-plt" \
            CGO_LDFLAGS="-Wl,-O1,--sort-common,--as-needed,-z,relro,-z,now" GOFLAGS="-buildmode=pie -trimpath -mod=readonly -modcacherw" \
            make GO_BUILDTAGS="apparmor selinux no_btrfs" "$@" VERSION=v1.4.0.m REVISION="$rev.m" binaries >"$WORK_DIR/build-$pkg.log" 2>&1 ) \
            || { echo "[setup] ERROR: $pkg did not compile with $("$GOROOT_DIR/bin/go" version); last lines:"; tail -25 "$WORK_DIR/build-$pkg.log"; exit 1; }
        sudo mkdir -p "$CACHE/$pkg"
        sudo cp -a "$SRC/bin/." "$CACHE/$pkg/"
        echo "  -> $pkg built"
    }
    build_pkg containerd-1.4.0-1 "$CTD_REV1" EXTRA_LDFLAGS="-linkmode external"
    build_pkg containerd-1.4.0-2 "$CTD_COMMIT"
    echo "go$GO_VERSION|$CTD_COMMIT" | sudo tee "$CACHE/go" >/dev/null
    sudo rm -rf "$WORK_DIR/gopath" "$WORK_DIR/gocache"
fi
for p in containerd-1.4.0-1 containerd-1.4.0-2; do echo "  $p: $("$CACHE/$p/containerd" --version 2>&1 | head -1)"; done

# ---- layout: the engineer's installation below LIB_BASE
echo "[setup] installing the engineer's stack below $LIB_BASE: the package cache, the link opt/containerd to the installed package (containerd 1.4.0-1),"
echo "[setup] the scripts bin/stack and bin/docker (containerd and the dockerd of this host on its own sockets; the docker of this host is not touched)..."
sudo mkdir -p "$LIB_BASE/bin" "$LIB_BASE/opt" "$LIB_BASE/packages" "$LIB_BASE/etc" "$LIB_BASE/containerd" "$LIB_BASE/docker" "$RUN_BASE/containerd" "$RUN_BASE/docker-exec"
for p in containerd-1.4.0-1 containerd-1.4.0-2; do sudo cp -a "$CACHE/$p" "$LIB_BASE/packages/$p"; done
sudo chown -R root:root "$LIB_BASE/packages"
sudo ln -sfn "$LIB_BASE/packages/containerd-1.4.0-1" "$LIB_BASE/opt/containerd"
cat <<CEOF | sudo tee "$LIB_BASE/etc/host.env" >/dev/null
# the programs of this host the engineer's stack uses
DOCKER=$DOCKER_BIN
DOCKERD=$DOCKERD_BIN
CEOF
cat <<CEOF | sudo tee "$LIB_BASE/etc/containerd.toml" >/dev/null
root = "$LIB_BASE/containerd"
state = "$RUN_BASE/containerd"
disabled_plugins = ["cri"]
[grpc]
  address = "$RUN_BASE/containerd.sock"
[debug]
  address = "$RUN_BASE/containerd-debug.sock"
CEOF
cat <<CEOF | sudo tee "$LIB_BASE/etc/daemon.json" >/dev/null
{
  "data-root": "$LIB_BASE/docker",
  "exec-root": "$RUN_BASE/docker-exec",
  "containerd": "$RUN_BASE/containerd.sock",
  "containerd-namespace": "$CASE_ID",
  "containerd-plugins-namespace": "$CASE_ID-plugins",
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
# The engineer's container stack: containerd of the installed package (the link /var/lib/bench63457756/opt/containerd) and, on top of it, the dockerd of
# this host (socket /run/bench63457756/docker.sock). containerd finds its shims and runc through PATH: the package directory first, then the host.
#   stack start | stop | restart | status
L=/var/lib/bench63457756
R=/run/bench63457756
OPT=$L/opt/containerd
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
    PATH="$OPT:$PATH" setsid sh -c 'echo $$ > "$1"; shift; exec "$@"' sh $R/containerd.pid \
        $OPT/containerd --config $L/etc/containerd.toml >>$R/containerd.log 2>&1 </dev/null &
    for _ in $(seq 1 100); do [ -S $R/containerd.sock ] && break; sleep 0.2; done
    setsid sh -c 'echo $$ > "$1"; shift; exec "$@"' sh $R/dockerd.pid \
        $DOCKERD --config-file $L/etc/daemon.json --host unix://$R/docker.sock >>$R/dockerd.log 2>&1 </dev/null &
    for _ in $(seq 1 150); do $DOCKER -H unix://$R/docker.sock version >/dev/null 2>&1 && break; sleep 0.3; done
    $DOCKER -H unix://$R/docker.sock version >/dev/null 2>&1 || { echo "stack: dockerd did not come up, see $R/dockerd.log" >&2; exit 1; }
    ;;
restart)
    $0 stop; $0 start
    ;;
status)
    for n in containerd dockerd; do
        pid=$(cat $R/$n.pid 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "$n: running (pid $pid, $(readlink /proc/$pid/exe))"; else echo "$n: not running"; fi
    done
    echo "installed package: $(readlink $OPT)"
    ;;
*)
    echo "usage: stack start|stop|restart|status" >&2; exit 2
    ;;
esac
CEOF
cat <<'CEOF' | sudo tee "$LIB_BASE/bin/docker" >/dev/null
#!/bin/sh
# the docker client of the engineer's daemon
. /var/lib/bench63457756/etc/host.env
exec $DOCKER -H unix:///run/bench63457756/docker.sock "$@"
CEOF
sudo chmod 755 "$LIB_BASE/bin/stack" "$LIB_BASE/bin/docker"

# ---- the workload: a static program that prints "nonce=" and its first argument and exits (with a second argument it then waits that many
# seconds, for the oracle's identity probe); the image is a docker archive made here (nothing is pulled)
echo "[setup] building the workload image offline (one static program, a docker archive for docker load)..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    printf("nonce=%s\n", argc > 1 ? argv[1] : "none");
    fflush(stdout);
    if (argc > 2) sleep((unsigned)atoi(argv[2]));
    return 0;
}
CEOF
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
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
python3 "$STATE_DIR/mkarchive.py" "$STATE_DIR/web.tar" "$IMAGE" "$STATE_DIR/app"

# ---- the engineer's steps: the stack with the installed containerd 1.4.0-1, the image loaded, the first docker run
DOCKER="$LIB_BASE/bin/docker"
echo "[setup] starting the engineer's stack (containerd from $(readlink "$LIB_BASE/opt/containerd") and the dockerd of this host)..."
sudo "$LIB_BASE/bin/stack" start >"$STATE_DIR/stack.out" 2>&1 \
    || { echo "[setup] ERROR: the stack did not start:"; cat "$STATE_DIR/stack.out"; tail -20 "$RUN_BASE/dockerd.log" "$RUN_BASE/containerd.log" 2>/dev/null; exit 1; }
sudo "$DOCKER" load -i "$STATE_DIR/web.tar" >"$STATE_DIR/load.log" 2>&1 || true
IMAGE_ID="$(sudo "$DOCKER" image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null | head -1)"
if [ -z "$IMAGE_ID" ]; then
    echo "[setup] ERROR: docker could not load the workload image:"; head -30 "$STATE_DIR/load.log"; tail -20 "$RUN_BASE/dockerd.log"; exit 1
fi
echo "  -> image $IMAGE loaded ($IMAGE_ID)"
SHIM1="$LIB_BASE/packages/containerd-1.4.0-1/containerd-shim-runc-v2"
SHIM2="$LIB_BASE/packages/containerd-1.4.0-2/containerd-shim-runc-v2"
set +e
{ sudo "$SHIM1" -v >"$STATE_DIR/shim1.out" 2>&1; RC1=$?; sudo "$SHIM2" -v >"$STATE_DIR/shim2.out" 2>&1; RC2=$?; } 2>/dev/null
set -e
if [ "$RC1" -le 128 ]; then
    echo "[setup] ERROR: the shim built with the recipe of containerd 1.4.0-1 does not die by a signal on this machine ($(uname -m)): exit $RC1, $(head -c 120 "$STATE_DIR/shim1.out" | tr '\n' ' ')"
    command -v readelf >/dev/null && readelf -h "$SHIM1" | grep -E "Type|Machine" | sed 's/^ */[setup]   /'
    echo "[setup] The defect of the question (Arch containerd 1.4.0-1: static link with -linkmode external on top of -buildmode=pie) exists on x86_64, where Go 1.15's"
    echo "[setup] start-up of the shim aborts with SIGTRAP; with the same recipe on $(uname -m) the shim starts and docker run works, so the failure cannot be reproduced here."
    exit 1
fi
if [ "$RC2" -ne 0 ] || ! grep -q "v1.4.0" "$STATE_DIR/shim2.out"; then
    echo "[setup] ERROR: the shim of containerd 1.4.0-2 does not run (exit $RC2): $(head -c 200 "$STATE_DIR/shim2.out")"; exit 1
fi
echo "  -> the shim of 1.4.0-1 dies by signal $((RC1 - 128)) at start (exit $RC1), the shim of 1.4.0-2 prints its version"
echo "[setup] the engineer's docker run (the daemon has no bridge network, the container runs with --network none)..."
NONCE="first-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
if sudo "$DOCKER" run --rm --network none "$IMAGE" "$NONCE" >"$STATE_DIR/run.out" 2>"$STATE_DIR/run.err"; then
    echo "[setup] ERROR: docker run worked: the failure of the question did not appear with these packages"; cat "$STATE_DIR/run.out"; exit 1
fi
if grep -q "nonce=$NONCE" "$STATE_DIR/run.out"; then echo "[setup] ERROR: the container printed its nonce although docker run failed"; exit 1; fi
echo "  -> docker run fails: $(head -1 "$STATE_DIR/run.err" | cut -c1-200)"

echo "[setup] recording what is true now (versions, hashes, the image)..."
{
    echo "# the stack of the engineer before the upgrade was repaired"
    echo "docker client:  $($DOCKER_BIN --version | head -1)"
    echo "dockerd:        $($DOCKERD_BIN --version | head -1)  ($DOCKERD_BIN)"
    echo "runc:           $(runc --version | head -1)  ($RUNC_BIN)"
    echo "containerd installed:    containerd-1.4.0-1 ($(readlink "$LIB_BASE/opt/containerd"))"
    echo "containerd in the cache: containerd-1.4.0-1, containerd-1.4.0-2 ($LIB_BASE/packages)"
    echo "shim of the installed package: $SHIM1"
    echo "image:          $IMAGE  $IMAGE_ID"
} | sudo tee "$LIB_BASE/etc/versions.txt" >/dev/null
echo "$IMAGE_ID" | sudo tee "$STATE_DIR/image.id" >/dev/null
( cd "$LIB_BASE/packages" && sudo find . -type f -exec sha256sum {} + | sort -k2 ) | sudo tee "$STATE_DIR/packages.sha" >/dev/null
( cd "$LIB_BASE" && sudo sha256sum bin/stack bin/docker etc/host.env etc/containerd.toml etc/daemon.json ) | sudo tee "$STATE_DIR/scripts.sha" >/dev/null
echo "$RUNC_BIN $(sha256sum "$RUNC_BIN" | awk '{print $1}') $(runc --version | head -1 | tr ' ' '_')" | sudo tee "$STATE_DIR/runc.rec" >/dev/null
echo "$DOCKERD_BIN $(sha256sum "$DOCKERD_BIN" | awk '{print $1}')" | sudo tee "$STATE_DIR/dockerd.rec" >/dev/null
sudo chmod 755 "$STATE_DIR"
sudo chmod 600 "$STATE_DIR"/image.id "$STATE_DIR"/packages.sha "$STATE_DIR"/scripts.sha "$STATE_DIR"/runc.rec "$STATE_DIR"/dockerd.rec

echo "[setup] removing the build inputs..."
sudo rm -rf "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/mkarchive.py" "$STATE_DIR/web.tar" "$STATE_DIR"/run.* "$STATE_DIR"/shim*.out "$STATE_DIR/load.log" "$STATE_DIR/stack.out"

echo "[setup] done. The stack runs with containerd 1.4.0-1 installed; docker run fails."
