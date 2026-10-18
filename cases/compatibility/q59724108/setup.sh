#!/bin/bash
set -e

CASE_ID="bench59724108"
RUN_BASE="/run/$CASE_ID"              # runroot, tmp dir (exit files) and logs of the engineer's podman
LIB_BASE="/var/lib/$CASE_ID"          # prefix of the engineer's podman: bin, libexec, packages, etc, storage, the data directory of the service
CACHE="/var/cache/$CASE_ID"           # the four compiled programs (kept by cleanup.sh)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
PODMAN="$LIB_BASE/bin/podman"
DATA="$LIB_BASE/data"
IMAGE="localhost/bench59724108/web:1"
CNAME="web"
PORT=8081

# sources, pinned by the commit of the tag (git ls-remote --tags): the checkout must be exactly this commit
PODMAN_BAD_TAG="v1.6.2";  PODMAN_BAD_COMMIT="f3ffda1e08f19e9a6a88484136b5eed76533f21a"     # the engineer's podman
PODMAN_NEW_TAG="v1.7.0";  PODMAN_NEW_COMMIT="b7ce1157b00af09f4a09e39b377aa3abff46ee05"     # the newer podman of the packages
CONMON_BAD_TAG="v2.0.3";  CONMON_BAD_COMMIT="eb5fa88c26fde5ce1e3f8a1d2a8a9498b2d7dbe6"     # the engineer's conmon
CONMON_OLD_TAG="v2.0.0";  CONMON_OLD_COMMIT="e217fdff82e0b1a6184a28c43043a4065083407f"     # the older conmon of the packages
# podman 1.6.2 / 1.7.0 vendor libraries of 2019 and crash at start-up (SIGSEGV "unexpected fault address") when built with the Go 1.18 of Ubuntu 22.04:
# they are built with the Go of their time (podman 1.6.2 was released with Go 1.13); this Go is only used to compile, it is not installed
PODMAN_GO_VERSION="1.13.15"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking runc, python3, sha256sum and the arguments of this machine..."
for b in runc python3 sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
case "$(uname -m)" in x86_64) GOARCH_NAME=amd64 ;; aarch64|arm64) GOARCH_NAME=arm64 ;; *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;; esac
RUNC="$(command -v runc)"
runc --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking nothing of this host is in the way: the port $PORT is free (the service of the case listens on the host network)..."
python3 - "$PORT" <<'PYEOF' || { echo "[setup] ERROR: port $PORT is in use on this host"; exit 1; }
import socket
import sys

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)      # as the service does: connections in TIME_WAIT of an earlier run do not count
s.bind(("0.0.0.0", int(sys.argv[1])))
s.listen(1)
PYEOF

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$CACHE"
cd "$WORK_DIR"

# ---- the four programs: podman 1.6.2 and conmon 2.0.3 (the engineer's), conmon 2.0.0 and podman 1.7.0 (the packages). Compiled from the
# pinned commits once, kept in the cache; BENCH59724108_BUILDS_DIR names a directory that already has the four files (no compiling)
# a podman binary in the cache that was not built with that Go is thrown away
if [ -z "${BENCH59724108_BUILDS_DIR:-}" ] && [ "$(sudo cat "$CACHE/podman-go" 2>/dev/null)" != "go$PODMAN_GO_VERSION" ]; then
    sudo rm -f "$CACHE/podman-${PODMAN_BAD_TAG#v}" "$CACHE/podman-${PODMAN_NEW_TAG#v}" "$CACHE/podman-go"
fi
need=""
for f in podman-${PODMAN_BAD_TAG#v} podman-${PODMAN_NEW_TAG#v} conmon-${CONMON_BAD_TAG#v} conmon-${CONMON_OLD_TAG#v}; do
    if [ -n "${BENCH59724108_BUILDS_DIR:-}" ] && [ -f "$BENCH59724108_BUILDS_DIR/$f" ]; then sudo install -m 755 "$BENCH59724108_BUILDS_DIR/$f" "$CACHE/$f"; fi
    sudo test -x "$CACHE/$f" || need="$need $f"
done
if [ -n "$need" ]; then
    echo "[setup] compiling what is not cached yet:$need (first run only; several minutes)..."
    for b in git gcc make pkg-config curl; do command -v "$b" >/dev/null || NEED_APT=1; done
    pkg-config --exists glib-2.0 2>/dev/null || NEED_APT=1
    pkg-config --exists libseccomp 2>/dev/null || NEED_APT=1
    if [ -n "${NEED_APT:-}" ]; then
        sudo -E apt-get update -qq
        sudo -E apt-get install -y -qq "${APT_OPTS[@]}" git gcc make pkg-config curl libglib2.0-dev libseccomp-dev
    fi
    GO="$CACHE/go$PODMAN_GO_VERSION/bin/go"
    case "$need" in *podman-*)
        if ! sudo test -x "$GO"; then
            echo "[setup] fetching the Go $PODMAN_GO_VERSION toolchain for podman (sha256 checked against the list of go.dev)..."
            GO_TAR="go$PODMAN_GO_VERSION.linux-$GOARCH_NAME.tar.gz"
            mkdir -p "$WORK_DIR/dl"
            curl -fsSL --retry 3 -o "$WORK_DIR/dl/$GO_TAR" "https://go.dev/dl/$GO_TAR" \
                || { echo "[setup] ERROR: could not download https://go.dev/dl/$GO_TAR"; exit 1; }
            GO_SUM="$(curl -fsSL --retry 3 "https://go.dev/dl/?mode=json&include=all" \
                | python3 -c 'import json,sys; f=sys.argv[1]; print(next(x["sha256"] for r in json.load(sys.stdin) for x in r["files"] if x["filename"]==f))' "$GO_TAR")" \
                || { echo "[setup] ERROR: no sha256 for $GO_TAR in the list of go.dev"; exit 1; }
            echo "$GO_SUM  $WORK_DIR/dl/$GO_TAR" | sha256sum -c --status || { echo "[setup] ERROR: sha256 of $GO_TAR does not match"; exit 1; }
            sudo mkdir -p "$CACHE/go$PODMAN_GO_VERSION"
            sudo tar -xzf "$WORK_DIR/dl/$GO_TAR" -C "$CACHE/go$PODMAN_GO_VERSION" --strip-components=1
            rm -rf "$WORK_DIR/dl"
        fi
        "$GO" version ;;
    esac
    mkdir -p "$WORK_DIR/src"
    clone() {   # $1 = repository, $2 = tag, $3 = commit, $4 = directory
        git clone --quiet --depth 1 --branch "$2" "https://github.com/containers/$1.git" "$4" >/dev/null 2>&1 \
            || { echo "[setup] ERROR: could not clone $1 $2"; exit 1; }
        [ "$(git -C "$4" rev-parse HEAD)" = "$3" ] || { echo "[setup] ERROR: $1 $2 is not the pinned commit $3"; exit 1; }
    }
    build_conmon() {    # $1 = tag, $2 = commit, $3 = output name
        sudo test -x "$CACHE/$3" && return 0
        clone conmon "$1" "$2" "$WORK_DIR/src/$3"
        sed -i 's/-Werror//g' "$WORK_DIR/src/$3/Makefile"
        ( cd "$WORK_DIR/src/$3" && make bin/conmon >"$WORK_DIR/build-$3.log" 2>&1 ) \
            || { echo "[setup] ERROR: conmon $1 did not compile; last lines:"; tail -20 "$WORK_DIR/build-$3.log"; exit 1; }
        sudo install -m 755 "$WORK_DIR/src/$3/bin/conmon" "$CACHE/$3"
        echo "  -> $3 built"
    }
    build_podman() {    # $1 = tag, $2 = commit, $3 = output name
        sudo test -x "$CACHE/$3" && return 0
        clone podman "$1" "$2" "$WORK_DIR/src/$3"
        ( cd "$WORK_DIR/src/$3" && GO111MODULE=on GOFLAGS=-mod=vendor GOPATH="$WORK_DIR/gopath" GOCACHE="$WORK_DIR/gocache" CGO_ENABLED=1 \
            "$GO" build -tags "exclude_graphdriver_btrfs exclude_graphdriver_devicemapper containers_image_ostree_stub containers_image_openpgp" \
            -o "$WORK_DIR/src/$3/podman.bin" ./cmd/podman >"$WORK_DIR/build-$3.log" 2>&1 ) \
            || { echo "[setup] ERROR: podman $1 did not compile with $($GO version); last lines:"; tail -25 "$WORK_DIR/build-$3.log"; exit 1; }
        sudo install -m 755 "$WORK_DIR/src/$3/podman.bin" "$CACHE/$3"
        echo "  -> $3 built"
    }
    build_conmon "$CONMON_BAD_TAG" "$CONMON_BAD_COMMIT" "conmon-${CONMON_BAD_TAG#v}"
    build_conmon "$CONMON_OLD_TAG" "$CONMON_OLD_COMMIT" "conmon-${CONMON_OLD_TAG#v}"
    build_podman "$PODMAN_BAD_TAG" "$PODMAN_BAD_COMMIT" "podman-${PODMAN_BAD_TAG#v}"
    build_podman "$PODMAN_NEW_TAG" "$PODMAN_NEW_COMMIT" "podman-${PODMAN_NEW_TAG#v}"
    echo "go$PODMAN_GO_VERSION" | sudo tee "$CACHE/podman-go" >/dev/null
    sudo rm -rf "$WORK_DIR/src" "$WORK_DIR/gopath" "$WORK_DIR/gocache"
fi
for f in podman-${PODMAN_BAD_TAG#v} podman-${PODMAN_NEW_TAG#v}; do echo "  $("$CACHE/$f" --version 2>&1 | head -1)"; done
for f in conmon-${CONMON_BAD_TAG#v} conmon-${CONMON_OLD_TAG#v}; do echo "  $("$CACHE/$f" --version 2>&1 | head -1)"; done

# ---- layout: the engineer's installation below LIB_BASE
echo "[setup] installing the engineer's podman below $LIB_BASE: podman ${PODMAN_BAD_TAG#v} and conmon ${CONMON_BAD_TAG#v} in libexec, the other two"
echo "[setup] programs in packages, the wrapper $PODMAN (own storage, runroot and tmp dir; the podman of this host is not touched)..."
sudo mkdir -p "$LIB_BASE/bin" "$LIB_BASE/libexec" "$LIB_BASE/packages" "$LIB_BASE/etc" "$LIB_BASE/storage" "$LIB_BASE/cni" "$DATA" "$RUN_BASE/storage" "$RUN_BASE/tmp"
sudo install -m 755 "$CACHE/podman-${PODMAN_BAD_TAG#v}" "$LIB_BASE/libexec/podman"
sudo install -m 755 "$CACHE/conmon-${CONMON_BAD_TAG#v}" "$LIB_BASE/libexec/conmon"
sudo install -m 755 "$CACHE/podman-${PODMAN_NEW_TAG#v}" "$LIB_BASE/packages/podman-${PODMAN_NEW_TAG#v}"
sudo install -m 755 "$CACHE/conmon-${CONMON_OLD_TAG#v}" "$LIB_BASE/packages/conmon-${CONMON_OLD_TAG#v}"
cat <<CEOF | sudo tee "$LIB_BASE/etc/podman.env" >/dev/null
# the programs the wrapper $PODMAN runs
PODMAN=$LIB_BASE/libexec/podman
CONMON=$LIB_BASE/libexec/conmon
CEOF
cat <<CEOF | sudo tee "$LIB_BASE/libexec/runc" >/dev/null
#!/bin/sh
# runc of this host (podman 1.6.2 finds it as "runc"). Before it creates a container, a container with the same id that an earlier failed start
# left in runc is deleted: conmon 2.0.3 forks "runc create" and then dies at the old FIFO while the create still ends; runc $(runc --version | head -1 | awk '{print $3}')
# keeps that container, and the next start would only say "container with given ID already exists", a second error that has nothing to do with the case
for a in "\$@"; do
    if [ "\$a" = create ]; then for id; do :; done; $RUNC delete --force "\$id" >/dev/null 2>&1; break; fi
done
exec $RUNC "\$@"
CEOF
sudo chmod 755 "$LIB_BASE/libexec/runc"
cat <<CEOF | sudo tee "$PODMAN" >/dev/null
#!/bin/sh
# the engineer's podman: its own storage, runroot and tmp dir; the programs are named in $LIB_BASE/etc/podman.env
. $LIB_BASE/etc/podman.env
exec "\$PODMAN" --root $LIB_BASE/storage --runroot $RUN_BASE/storage --tmpdir $RUN_BASE/tmp --storage-driver vfs \\
    --runtime $LIB_BASE/libexec/runc --conmon "\$CONMON" --cgroup-manager cgroupfs --events-backend file --cni-config-dir $LIB_BASE/cni "\$@"
CEOF
sudo chmod 755 "$PODMAN"
"$PODMAN" --version | head -1

# ---- the service: a static program that appends a line to /data/boots at every start and answers HTTP on port 8081 with its token and the
# number of lines of that file; the image is a docker archive made here (nothing is pulled)
echo "[setup] building the service image offline (one static program, a docker archive for podman load)..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void bye(int sig) { _exit(0); }

int main(int argc, char **argv) {
    const char *token = argc > 1 ? argv[1] : "none";
    const char *dir = getenv("DATA_DIR") ? getenv("DATA_DIR") : "/data";
    char path[512], line[256];
    int boots = 0;
    snprintf(path, sizeof path, "%s/boots", dir);
    FILE *f = fopen(path, "a");
    if (f) { fprintf(f, "boot pid=%d token=%s\n", (int)getpid(), token); fclose(f); }
    f = fopen(path, "r");
    if (f) { while (fgets(line, sizeof line, f)) boots++; fclose(f); }
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    signal(SIGPIPE, SIG_IGN);
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons(8081);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 16) < 0) { perror("bind"); return 1; }
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) continue;
        char req[1024];
        (void)!read(c, req, sizeof req);
        char body[256];
        int n = snprintf(body, sizeof body, "bench59724108 token=%s boots=%d\n", token, boots);
        char head[256];
        int m = snprintf(head, sizeof head, "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n", n);
        (void)!write(c, head, m);
        (void)!write(c, body, n);
        close(c);
    }
}
CEOF
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
cat > "$STATE_DIR/mkarchive.py" <<'PYEOF'
"""mkarchive.py OUT REF PROGRAM : a one-layer docker archive (docker save format) with PROGRAM as /app and an empty /data"""
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
    d = tarfile.TarInfo("data")
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 1700000000
    t.addfile(d)
    with open(prog, "rb") as f:
        data = f.read()
    ti = tarfile.TarInfo("app")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], "Entrypoint": ["/app"], "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps([{"Config": sha(config) + ".json", "RepoTags": [ref], "Layers": [sha(layer) + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for name, payload in (("manifest.json", manifest), (sha(config) + ".json", config), (sha(layer) + "/layer.tar", layer)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(payload), 1700000000
        t.addfile(ti, io.BytesIO(payload))
PYEOF
python3 "$STATE_DIR/mkarchive.py" "$STATE_DIR/web.tar" "$IMAGE" "$STATE_DIR/app"
sudo "$PODMAN" load -i "$STATE_DIR/web.tar" >"$STATE_DIR/load.log" 2>&1 || true
tail -1 "$STATE_DIR/load.log"
IMAGE_ID="$(sudo "$PODMAN" inspect --format '{{.ID}}' "$IMAGE" 2>/dev/null | head -1)"
if [ -z "$IMAGE_ID" ]; then
    echo "[setup] ERROR: podman could not load the service image; the start of its output (cache built with $(sudo cat "$CACHE/podman-go" 2>/dev/null)):"
    head -30 "$STATE_DIR/load.log"
    exit 1
fi

# ---- the engineer's original steps: run, stop, start
echo "[setup] the engineer's steps: run the container $CNAME (the data directory $DATA mounted on /data, the port $PORT), stop it, start it again..."
sudo sh -c 'head -c 65536 /dev/urandom > "$1/keep.bin"' _ "$DATA"
KEEP_SHA="$(sudo sha256sum "$DATA/keep.bin" | awk '{print $1}')"
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
CID="$(sudo "$PODMAN" run -d --name "$CNAME" --network host -v "$DATA:/data" "$IMAGE" "$TOKEN" 2>"$STATE_DIR/run.err" | tail -1)" || true
echo "$CID" | grep -Eq '^[0-9a-f]{64}$' || { echo "[setup] ERROR: podman run -d failed:"; cut -c1-300 "$STATE_DIR/run.err"; exit 1; }
for _ in $(seq 1 30); do
    python3 - "$PORT" "$TOKEN" <<'PYEOF' && break
import sys
import urllib.request

body = urllib.request.urlopen("http://127.0.0.1:%s/" % sys.argv[1], timeout=2).read().decode()
sys.exit(0 if "token=" + sys.argv[2] in body else 1)
PYEOF
    sleep 1
done
python3 - "$PORT" "$TOKEN" <<'PYEOF' || { echo "[setup] ERROR: the service does not answer after podman run"; sudo "$PODMAN" ps -a 2>&1 | head -3; exit 1; }
import sys
import urllib.request

body = urllib.request.urlopen("http://127.0.0.1:%s/" % sys.argv[1], timeout=3).read().decode()
sys.exit(0 if "token=" + sys.argv[2] in body and "boots=1" in body else 1)
PYEOF
echo "  -> container ${CID:0:12} runs, the service answers (boots=1)"
settle() {      # a stop or a failed start leaves processes of the container that are still finishing (conmon, runc create, podman container cleanup)
    for _ in $(seq 1 200); do
        pgrep -f "$CID" >/dev/null 2>&1 || return 0
        sleep 0.2
    done
}
sudo "$PODMAN" stop "$CNAME" >/dev/null 2>&1 || { echo "[setup] ERROR: podman stop failed"; exit 1; }
settle
if sudo "$PODMAN" start "$CNAME" >"$STATE_DIR/start.out" 2>&1; then
    echo "[setup] ERROR: podman start worked: the failure of the question did not appear with these programs"
    exit 1
fi
settle
# the fact that counts is the FIFO conmon 2.0.3 left; the text of the error differs with the timing (EOF, or the error of the runc create conmon left behind)
sudo find "$LIB_BASE/storage" -type p -name winsz -path "*/$CID/*" | grep -q . \
    || { echo "[setup] ERROR: podman start failed, but no winsz FIFO is left: another error:"; cut -c1-400 "$STATE_DIR/start.out"; exit 1; }
echo "  -> podman start fails: $(grep -o 'unable to start container.*' "$STATE_DIR/start.out" | head -1 | cut -c1-150); the FIFO winsz is left in the container directory"

echo "[setup] recording what is true now (ids, hashes, the first lines of the data)..."
sudo "$PODMAN" inspect --format '{{.ID}}|{{.Created}}|{{.Image}}' "$CNAME" | sudo tee "$STATE_DIR/web.rec" >/dev/null
echo "$TOKEN" | sudo tee "$STATE_DIR/token" >/dev/null
echo "$KEEP_SHA" | sudo tee "$STATE_DIR/keep.sha" >/dev/null
sudo head -1 "$DATA/boots" | sudo tee "$STATE_DIR/boots.first" >/dev/null
sudo wc -l < "$DATA/boots" | tr -d ' ' | sudo tee "$STATE_DIR/boots.count" >/dev/null
echo "$IMAGE_ID" | sudo tee "$STATE_DIR/image.id" >/dev/null
sudo sha256sum "$PODMAN" | awk '{print $1}' | sudo tee "$STATE_DIR/wrapper.sha" >/dev/null
sudo chmod 755 "$STATE_DIR"
sudo chmod 600 "$STATE_DIR"/web.rec "$STATE_DIR"/token "$STATE_DIR"/keep.sha "$STATE_DIR"/boots.* "$STATE_DIR"/image.id "$STATE_DIR"/wrapper.sha

echo "[setup] removing the build inputs..."
sudo rm -rf "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/mkarchive.py" "$STATE_DIR/web.tar" "$STATE_DIR/run.err" "$STATE_DIR/start.out"

echo "[setup] done. The container $CNAME ran and was stopped; podman start fails."
