#!/bin/bash
set -e

CASE_ID="bench66733729"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files and logs of containerd and BuildKit
LIB_BASE="/var/lib/$CASE_ID"          # bin (control scripts), etc (configuration), the roots of both daemons, libexec (buildkitd, buildctl), demo (the build context), app (the Go program)
CTL_DIR="$LIB_BASE/bin"               # control scripts (not in /run: it is mounted noexec on many hosts)
LIBEXEC="$LIB_BASE/libexec"
DEMO_DIR="$LIB_BASE/demo"             # the engineer's build context: Dockerfile, hasher, payload.bin
APP_DIR="$LIB_BASE/app"               # the engineer's Go program (owned by the user who runs the setup)
CACHE="/var/cache/$CASE_ID"           # the downloaded and checked BuildKit release and the Go toolchain (kept by cleanup.sh)
CTD_SOCK="$RUN_BASE/containerd.sock"
BK_SOCK="$RUN_BASE/buildkitd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NS="bench66733729"                    # the containerd namespace of the engineer's program (BuildKit's worker uses another one: buildkit)
REF="docker.io/library/bench66733729-app:1"

BUILDKIT_VERSION="v0.23.2"            # the Go modules of the starter (go.mod) are the ones of this release
case "$(uname -m)" in
    x86_64)        BK_ASSET="buildkit-$BUILDKIT_VERSION.linux-amd64.tar.gz"; BK_SHA256="2771c3403e3a1f75a83cde387a05365794d3b900c355e864772a36c3ce541f82" ;;
    aarch64|arm64) BK_ASSET="buildkit-$BUILDKIT_VERSION.linux-arm64.tar.gz"; BK_SHA256="6385ff70b2fb4134b50ac3183eea3a0b06c6f6129173940d73178ae0477368f1" ;;
    *)             BK_ASSET=""; BK_SHA256="" ;;
esac

# the Go of the machine is not used (Debian/Ubuntu ship 1.18, too old for these modules, and a Go older than 1.21 cannot fetch a newer toolchain itself):
# setup installs this release next to the other pinned downloads and writes the wrapper $CTL_DIR/go for it
GO_VERSION="1.24.7"
case "$(uname -m)" in
    x86_64)        GO_ARCH="amd64" ;;
    aarch64|arm64) GO_ARCH="arm64" ;;
    *)             GO_ARCH="" ;;
esac
GO_ASSET="go$GO_VERSION.linux-$GO_ARCH.tar.gz"
GO_ROOT="$CACHE/go$GO_VERSION-$GO_ARCH"

echo "[setup] checking containerd, its shim, runc, ctr, gcc, curl, tar, python3 and sha256sum of this machine..."
for b in containerd containerd-shim-runc-v2 runc ctr gcc curl tar python3 sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found (the case needs a C compiler on the machine)"; exit 1; }
done
[ -n "$BK_ASSET" ] || { echo "[setup] ERROR: no BuildKit is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
[ -n "$GO_ARCH" ] || { echo "[setup] ERROR: no Go toolchain is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
echo "  host: $(containerd --version | head -1), $(runc --version | head -1), $(uname -m), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
chmod 700 "$STATE_DIR"
cd "$WORK_DIR"
# the runc state of containers lives below /run/containerd/runc/<namespace> (a shared place): record what is there now, and whether /run/containerd exists
sudo mkdir -p "$LIB_BASE"
[ -e /run/containerd ] || sudo touch "$LIB_BASE/run_containerd_created"
sudo sh -c "find /run/containerd/runc -mindepth 1 -maxdepth 2 2>/dev/null | sort > \"$LIB_BASE/runc.before\""

echo "[setup] BuildKit $BUILDKIT_VERSION: from the cache $CACHE, else downloaded; the sha256 is checked either way..."
sudo mkdir -p "$CACHE" "$CTL_DIR" "$LIBEXEC" "$LIB_BASE/etc" "$LIB_BASE/containerd" "$LIB_BASE/buildkit/root" "$DEMO_DIR" "$RUN_BASE/containerd"
if ! { sudo test -f "$CACHE/$BK_ASSET" && echo "$BK_SHA256  $CACHE/$BK_ASSET" | sudo sha256sum -c - >/dev/null 2>&1; }; then
    if [ -n "${BENCH66733729_BUILDKIT_TGZ:-}" ]; then cp "$BENCH66733729_BUILDKIT_TGZ" "$STATE_DIR/download"
    else curl -fsSL --retry 3 --max-time 600 -o "$STATE_DIR/download" "https://github.com/moby/buildkit/releases/download/$BUILDKIT_VERSION/$BK_ASSET" || { echo "[setup] ERROR: could not download BuildKit $BUILDKIT_VERSION"; exit 1; }
    fi
    echo "$BK_SHA256  $STATE_DIR/download" | sha256sum -c - >/dev/null 2>&1 || { echo "[setup] ERROR: the BuildKit archive has the wrong sha256"; exit 1; }
    sudo install -m 644 "$STATE_DIR/download" "$CACHE/$BK_ASSET"
    rm -f "$STATE_DIR/download"
fi
tar -xzf "$CACHE/$BK_ASSET" -C "$STATE_DIR" bin/buildkitd bin/buildctl
sudo install -m 755 "$STATE_DIR/bin/buildkitd" "$STATE_DIR/bin/buildctl" "$LIBEXEC/"

echo "[setup] Go $GO_VERSION (the case's own toolchain, not the one of the machine): from the cache $CACHE, else downloaded and checked against the sha256 published by the Go project..."
if ! sudo test -x "$GO_ROOT/bin/go"; then
    if [ -n "${BENCH66733729_GO_TGZ:-}" ]; then cp "$BENCH66733729_GO_TGZ" "$STATE_DIR/gotgz"
    else
        for base in https://dl.google.com/go https://go.dev/dl; do
            curl -fsSL --retry 3 --max-time 900 -o "$STATE_DIR/gotgz" "$base/$GO_ASSET" && break
        done
        [ -s "$STATE_DIR/gotgz" ] || { echo "[setup] ERROR: could not download Go $GO_VERSION ($GO_ASSET from dl.google.com or go.dev)"; exit 1; }
        GO_SHA="${BENCH66733729_GO_SHA256:-}"
        [ -n "$GO_SHA" ] || GO_SHA="$(curl -fsSL --retry 3 --max-time 60 "https://dl.google.com/go/$GO_ASSET.sha256" | awk 'NR==1{print $1}')"
        echo "$GO_SHA" | grep -Eq '^[0-9a-f]{64}$' || { echo "[setup] ERROR: no sha256 for $GO_ASSET could be read (set BENCH66733729_GO_SHA256)"; exit 1; }
        echo "$GO_SHA  $STATE_DIR/gotgz" | sha256sum -c - >/dev/null 2>&1 || { echo "[setup] ERROR: the Go archive has the wrong sha256"; exit 1; }
    fi
    sudo rm -rf "$GO_ROOT.tmp"
    sudo mkdir -p "$GO_ROOT.tmp"
    sudo tar -xzf "$STATE_DIR/gotgz" -C "$GO_ROOT.tmp" --strip-components=1
    sudo chmod -R a+rX "$GO_ROOT.tmp"
    sudo mv "$GO_ROOT.tmp" "$GO_ROOT"
    rm -f "$STATE_DIR/gotgz"
fi
sudo test -x "$GO_ROOT/bin/go" || { echo "[setup] ERROR: the Go toolchain is not usable"; exit 1; }
sudo tee "$CTL_DIR/go" >/dev/null <<EOF
#!/bin/sh
# go $GO_VERSION of this lab (the go of the machine is not used); it never fetches another toolchain
GOROOT="$GO_ROOT"; GOTOOLCHAIN=local; PATH="\$GOROOT/bin:\$PATH"
export GOROOT GOTOOLCHAIN PATH
exec "\$GOROOT/bin/go" "\$@"
EOF
sudo chmod 755 "$CTL_DIR/go"
echo "  -> $("$CTL_DIR/go" version)"
"$LIBEXEC/buildkitd" --version

echo "[setup] configuration and control scripts: containerd on $CTD_SOCK, BuildKit with a containerd worker on $BK_SOCK..."
cat <<CEOF | sudo tee "$LIB_BASE/etc/containerd.toml" >/dev/null
version = 2
root = "$LIB_BASE/containerd"
state = "$RUN_BASE/containerd"
disabled_plugins = ["io.containerd.grpc.v1.cri"]
[grpc]
  address = "$CTD_SOCK"
[plugins."io.containerd.nri.v1.nri"]
  disable = true
CEOF
# BuildKit's containerd worker keeps what it builds in the containerd namespace "buildkit" (not in the namespace of the engineer's program)
cat <<CEOF | sudo tee "$LIB_BASE/etc/buildkitd.toml" >/dev/null
root = "$LIB_BASE/buildkit/root"

[grpc]
  address = ["unix://$BK_SOCK"]

[worker.oci]
  enabled = false

[worker.containerd]
  enabled = true
  address = "$CTD_SOCK"
  namespace = "buildkit"
CEOF
cat <<CEOF | sudo tee "$CTL_DIR/containerdctl" >/dev/null
#!/bin/bash
# how containerd is started and stopped on this machine: containerdctl start|stop|restart|status (it reads $LIB_BASE/etc/containerd.toml)
PIDF="$RUN_BASE/containerd.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "containerd is already running"; return 0; fi
    mkdir -p "$RUN_BASE/containerd"
    setsid -f bash -c 'echo \$\$ > "\$1"; exec "\$2" --config "\$3" >>"\$4" 2>&1 </dev/null' _ "\$PIDF" "$(command -v containerd)" "$LIB_BASE/etc/containerd.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
    for _ in \$(seq 1 100); do [ -S "$CTD_SOCK" ] && break; sleep 0.2; done
    echo "containerd started"
}
do_stop() {
    alive || { echo "containerd is not running"; return 0; }
    kill -TERM "\$(cat "\$PIDF")"
    for _ in \$(seq 1 50); do alive || break; sleep 0.2; done
    alive && kill -KILL "\$(cat "\$PIDF")"
    echo "containerd stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid \$(cat "\$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: containerdctl start|stop|restart|status"; exit 2 ;;
esac
CEOF
cat <<CEOF | sudo tee "$CTL_DIR/buildkitctl" >/dev/null
#!/bin/bash
# how BuildKit is started and stopped on this machine: buildkitctl start|stop|restart|status (it reads $LIB_BASE/etc/buildkitd.toml)
PIDF="$RUN_BASE/buildkitd.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "buildkitd is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec "\$2" --config "\$3" >>"\$4" 2>&1 </dev/null' _ "\$PIDF" "$LIBEXEC/buildkitd" "$LIB_BASE/etc/buildkitd.toml" "$RUN_BASE/buildkitd.log" </dev/null >/dev/null 2>&1
    for _ in \$(seq 1 100); do [ -S "$BK_SOCK" ] && break; sleep 0.2; done
    echo "buildkitd started"
}
do_stop() {
    alive || { echo "buildkitd is not running"; return 0; }
    kill -TERM "\$(cat "\$PIDF")"
    for _ in \$(seq 1 50); do alive || break; sleep 0.2; done
    alive && kill -KILL "\$(cat "\$PIDF")"
    echo "buildkitd stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid \$(cat "\$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: buildkitctl start|stop|restart|status"; exit 2 ;;
esac
CEOF
cat <<CEOF | sudo tee "$CTL_DIR/ctr" >/dev/null
#!/bin/sh
# ctr aimed at the containerd of this machine (the namespace is "default" unless -n or CONTAINERD_NAMESPACE says otherwise)
exec $(command -v ctr) -a $CTD_SOCK "\$@"
CEOF
cat <<CEOF | sudo tee "$CTL_DIR/buildctl" >/dev/null
#!/bin/sh
# buildctl aimed at the BuildKit daemon of this machine
exec $LIBEXEC/buildctl --addr unix://$BK_SOCK "\$@"
CEOF
sudo chmod 755 "$CTL_DIR"/containerdctl "$CTL_DIR"/buildkitctl "$CTL_DIR"/ctr "$CTL_DIR"/buildctl
sudo "$CTL_DIR/containerdctl" start >/dev/null
[ -S "$CTD_SOCK" ] || { echo "[setup] ERROR: containerd did not come up; last log lines:"; sudo tail -10 "$RUN_BASE/containerd.log" | cut -c1-200; exit 1; }
sudo "$CTL_DIR/buildkitctl" start >/dev/null
for _ in $(seq 1 60); do
    [ -S "$BK_SOCK" ] && sudo "$CTL_DIR/buildctl" debug workers >/dev/null 2>&1 && break
    sleep 0.5
done
if ! sudo "$CTL_DIR/buildctl" debug workers >/dev/null 2>&1; then
    echo "[setup] ERROR: buildkitd did not come up; last log lines:"
    sudo tail -10 "$RUN_BASE/buildkitd.log" 2>/dev/null | cut -c1-200 || true
    exit 1
fi
echo "  -> containerd and buildkitd up"

# ---- the engineer's build context: a static program (sha256 of a file) and a random file; nothing is pulled, the Dockerfile starts FROM scratch
echo "[setup] the engineer's build context $DEMO_DIR: Dockerfile, hasher (a static program) and payload.bin (1 MiB of random bytes)..."
cat > "$STATE_DIR/hasher.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include <string.h>

typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t n; } sha_t;
static const uint32_t K[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
#define R(x,n) (((x)>>(n))|((x)<<(32-(n))))
static void block(sha_t *s, const uint8_t *p) {
    uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2; int i;
    for (i = 0; i < 16; i++) w[i] = (uint32_t)p[4*i]<<24 | p[4*i+1]<<16 | p[4*i+2]<<8 | p[4*i+3];
    for (i = 16; i < 64; i++) {
        uint32_t s0 = R(w[i-15],7) ^ R(w[i-15],18) ^ (w[i-15]>>3), s1 = R(w[i-2],17) ^ R(w[i-2],19) ^ (w[i-2]>>10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    a=s->h[0]; b=s->h[1]; c=s->h[2]; d=s->h[3]; e=s->h[4]; f=s->h[5]; g=s->h[6]; h=s->h[7];
    for (i = 0; i < 64; i++) {
        t1 = h + (R(e,6)^R(e,11)^R(e,25)) + ((e&f)^(~e&g)) + K[i] + w[i];
        t2 = (R(a,2)^R(a,13)^R(a,22)) + ((a&b)^(a&c)^(b&c));
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    s->h[0]+=a; s->h[1]+=b; s->h[2]+=c; s->h[3]+=d; s->h[4]+=e; s->h[5]+=f; s->h[6]+=g; s->h[7]+=h;
}
static void init(sha_t *s) {
    static const uint32_t i0[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    memcpy(s->h, i0, sizeof i0); s->len = 0; s->n = 0;
}
static void update(sha_t *s, const uint8_t *p, size_t n) {
    s->len += n;
    while (n--) { s->buf[s->n++] = *p++; if (s->n == 64) { block(s, s->buf); s->n = 0; } }
}
static void final(sha_t *s, char *hex) {
    uint64_t bits = s->len * 8; uint8_t pad = 0x80; int i;
    update(s, &pad, 1); pad = 0;
    while (s->n != 56) update(s, &pad, 1);
    for (i = 7; i >= 0; i--) { uint8_t b = bits >> (8*i); update(s, &b, 1); }
    for (i = 0; i < 8; i++) sprintf(hex + 8*i, "%08x", s->h[i]);
}

/* hasher make IN OUT: writes the sha256 of IN, as 64 hex digits and a newline, to OUT.  hasher show FILE: prints FILE */
int main(int argc, char **argv) {
    uint8_t buf[65536]; size_t n; char hex[65]; sha_t s; FILE *f, *o;
    if (argc == 4 && !strcmp(argv[1], "make")) {
        if (!(f = fopen(argv[2], "rb"))) { perror(argv[2]); return 1; }
        init(&s);
        while ((n = fread(buf, 1, sizeof buf, f)) > 0) update(&s, buf, n);
        fclose(f); final(&s, hex);
        if (!(o = fopen(argv[3], "w"))) { perror(argv[3]); return 1; }
        fprintf(o, "%s\n", hex); fclose(o);
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "show")) {
        if (!(f = fopen(argv[2], "rb"))) { perror(argv[2]); return 1; }
        while ((n = fread(buf, 1, sizeof buf, f)) > 0) fwrite(buf, 1, n, stdout);
        fclose(f); return 0;
    }
    fprintf(stderr, "usage: hasher make IN OUT | hasher show FILE\n");
    return 2;
}
CEOF
gcc -static -Os -s -w -o "$STATE_DIR/hasher" "$STATE_DIR/hasher.c"
head -c 1048576 /dev/urandom > "$STATE_DIR/payload.bin"
sudo install -m 755 "$STATE_DIR/hasher" "$DEMO_DIR/hasher"
sudo install -m 644 "$STATE_DIR/payload.bin" "$DEMO_DIR/payload.bin"
cat <<'CEOF' | sudo tee "$DEMO_DIR/Dockerfile" >/dev/null
FROM scratch
COPY hasher /hasher
COPY payload.bin /payload.bin
RUN ["/hasher", "make", "/payload.bin", "/payload.sha256"]
ENTRYPOINT ["/hasher", "show", "/payload.sha256"]
CEOF
sudo chmod 644 "$DEMO_DIR/Dockerfile"

# ---- the engineer's Go program: the example of the containerd documentation (pull an image, make a container, run it), with the flags of the program the
# engineer wants: a build context and an image name. It still only pulls. go.mod pins the modules the BuildKit daemon of this machine goes with.
echo "[setup] the engineer's Go program $APP_DIR (main.go, go.mod): it pulls the image named by -tag and runs it..."
sudo mkdir -p "$APP_DIR"
sudo chown "$(id -u):$(id -g)" "$APP_DIR"
cat > "$APP_DIR/go.mod" <<'CEOF'
module bench66733729/app

go 1.23.0

require (
	github.com/containerd/containerd/v2 v2.1.3
	github.com/moby/buildkit v0.23.2
	github.com/tonistiigi/fsutil v0.0.0-20250605211040-586307ad452f
	golang.org/x/sync v0.14.0
)
CEOF
cat > "$APP_DIR/main.go" <<'CEOF'
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
)

const (
	containerdSock = "/run/bench66733729/containerd.sock"
	namespace      = "bench66733729"
)

func main() {
	contextDir := flag.String("context", "", "build context directory (with a Dockerfile)")
	tag := flag.String("tag", "", "image reference")
	flag.Parse()
	_ = contextDir
	if err := run(*tag); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(ref string) error {
	ctx := namespaces.WithNamespace(context.Background(), namespace)
	client, err := containerd.New(containerdSock)
	if err != nil {
		return err
	}
	defer client.Close()

	image, err := client.Pull(ctx, ref, containerd.WithPullUnpack)
	if err != nil {
		return err
	}
	id := fmt.Sprintf("bench66733729-run-%d", time.Now().UnixNano())
	container, err := client.NewContainer(ctx, id,
		containerd.WithImage(image),
		containerd.WithNewSnapshot(id+"-snapshot", image),
		containerd.WithNewSpec(oci.WithImageConfig(image)))
	if err != nil {
		return err
	}
	defer container.Delete(ctx, containerd.WithSnapshotCleanup)
	task, err := container.NewTask(ctx, cio.NewCreator(cio.WithStdio))
	if err != nil {
		return err
	}
	defer task.Delete(ctx)
	exit, err := task.Wait(ctx)
	if err != nil {
		return err
	}
	if err := task.Start(ctx); err != nil {
		return err
	}
	st := <-exit
	if code, _, _ := st.Result(); code != 0 {
		return fmt.Errorf("the container exited with %d", code)
	}
	return nil
}
CEOF

# the Go modules and the compiled packages of the BuildKit client and the containerd client go into the caches of this user now, so that the build of
# the engineer's program (and of a solution) is a matter of seconds; the program built here only holds the imports a build tool needs
echo "[setup] warming the Go module cache and the build cache (BuildKit client, containerd client)..."
mkdir -p "$STATE_DIR/warm"
cp "$APP_DIR/go.mod" "$STATE_DIR/warm/go.mod"
cat > "$STATE_DIR/warm/main.go" <<'CEOF'
package main

import (
	_ "github.com/containerd/containerd/v2/client"
	_ "github.com/containerd/containerd/v2/pkg/cio"
	_ "github.com/containerd/containerd/v2/pkg/namespaces"
	_ "github.com/containerd/containerd/v2/pkg/oci"
	_ "github.com/moby/buildkit/client"
	_ "github.com/tonistiigi/fsutil"
	_ "golang.org/x/sync/errgroup"
)

func main() {}
CEOF
( cd "$STATE_DIR/warm" && GOFLAGS=-mod=mod "$CTL_DIR/go" build -o warm . ) >"$STATE_DIR/warm.log" 2>&1 \
    || { echo "[setup] ERROR: the Go modules could not be fetched or built:"; tail -15 "$STATE_DIR/warm.log" | cut -c1-200; exit 1; }
( cd "$APP_DIR" && GOFLAGS=-mod=mod "$CTL_DIR/go" build -o "$STATE_DIR/starter" . ) >"$STATE_DIR/starter.log" 2>&1 \
    || { echo "[setup] ERROR: the engineer's program does not build:"; tail -15 "$STATE_DIR/starter.log" | cut -c1-200; exit 1; }
echo "  -> the program builds"

echo "[setup] recording what is true now (hashes of the files nobody may change, the oracle's own copy of hasher)..."
( cd "$LIB_BASE" && sudo sha256sum bin/containerdctl bin/buildkitctl bin/ctr bin/buildctl bin/go etc/containerd.toml etc/buildkitd.toml libexec/buildkitd libexec/buildctl demo/Dockerfile demo/hasher demo/payload.bin ) > "$STATE_DIR/files.sha"
cp "$STATE_DIR/hasher" "$STATE_DIR/hasher.keep"
chmod 600 "$STATE_DIR/files.sha"

echo "[setup] removing the build inputs..."
rm -rf "$STATE_DIR/hasher.c" "$STATE_DIR/hasher" "$STATE_DIR/payload.bin" "$STATE_DIR/bin" "$STATE_DIR/warm" "$STATE_DIR/warm.log" "$STATE_DIR/starter" "$STATE_DIR/starter.log"

echo "[setup] done. The program pulls an image that does not exist; BuildKit, which could build the Dockerfile, is not used."
