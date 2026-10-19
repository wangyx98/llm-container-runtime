#!/bin/bash
set -e

# Ubuntu 22.04/24.04 ship `needrestart`, which pops up an interactive
# whiptail dialog whenever apt upgrades a shared library as a dependency.
# That dialog needs a TTY and hangs forever when this script is run
# non-interactively by run_single_case.py / run_benchmark.py (subprocess
# with no stdin). Force both apt's own prompts and needrestart into fully
# automatic/non-interactive mode.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Pin CRI-O to the v1.34 stable stream and crictl to the matching v1.34.0
# release (crictl's own compatibility guidance: its minor version should
# match, or be at most one minor newer than, the CRI runtime's). v1.34 is
# the oldest stream still marked "Stable" (not end-of-life) on
# https://github.com/cri-o/packaging as of 2026-09, i.e. deliberately NOT
# the newest v1.38 stream -- a recent, actively-changing "latest" runtime
# package broke an earlier case in this benchmark with an upstream
# regression, so a slightly older, more battle-tested stable version is
# used here instead.
CRIO_VERSION="v1.34"
CRICTL_VERSION="v1.34.0"

# crictl's GitHub release ships separate per-arch tarballs (linux-amd64,
# linux-arm64, ...); unlike the apt-installed cri-o package (which apt
# resolves to the host's native arch automatically), this raw binary
# download must pick the right one explicitly -- an ARM64 host (e.g. a
# Multipass VM on Apple Silicon) given the amd64 tarball gets a binary
# that fails with "Exec format error" the moment it's run.
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    armv7l|armhf)   CRICTL_ARCH="arm" ;;
    ppc64le)        CRICTL_ARCH="ppc64le" ;;
    s390x)          CRICTL_ARCH="s390x" ;;
    *)
        echo "[setup] WARNING: unrecognized architecture '$(uname -m)', defaulting to amd64" >&2
        CRICTL_ARCH="amd64"
        ;;
esac

CASE_ID="bench71499683"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): truth.env, images.base, mkimage.py, hasher.keep, files.sha

echo "[setup] ensuring CRI-O is installed AT the pinned $CRIO_VERSION stream..."
echo "[setup] (not just 'installed at all' -- a host that already has a"
echo "[setup]  different crio version from an earlier experiment must be"
echo "[setup]  corrected to the pinned version, not left as-is)"
PINNED_CRIO_MINOR="${CRIO_VERSION#v}"
CURRENT_CRIO_VERSION=""
if command -v crio >/dev/null 2>&1; then
    CURRENT_CRIO_VERSION=$(crio --version 2>/dev/null | head -1 | awk '{print $3}')
fi
if [[ "$CURRENT_CRIO_VERSION" != "${PINNED_CRIO_MINOR}."* ]]; then
    echo "[setup] crio is '${CURRENT_CRIO_VERSION:-not installed}', pinned stream is $CRIO_VERSION -- (re)installing..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl gnupg ca-certificates

    # a stale apt source pinned to a DIFFERENT cri-o stream (e.g. left over
    # from an earlier manual install) would otherwise win version
    # resolution over the one we're about to add below.
    for f in /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        if grep -q "isv:/cri-o:/stable:/" "$f" 2>/dev/null; then
            echo "[setup]   removing pre-existing CRI-O apt source: $f"
            sudo rm -f "$f"
        fi
    done

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
        | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/cri-o.list > /dev/null

    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" --allow-downgrades --allow-change-held-packages cri-o
else
    echo "[setup] crio $CURRENT_CRIO_VERSION already matches the pinned $CRIO_VERSION stream, skipping install."
fi

echo "[setup] confirming crio binary is on PATH..."
command -v crio
crio --version | head -1

echo "[setup] ensuring crictl is installed AT the pinned $CRICTL_VERSION (matching CRI-O's minor)..."
CURRENT_CRICTL_VERSION=""
if command -v crictl >/dev/null 2>&1; then
    CURRENT_CRICTL_VERSION=$(crictl --version 2>/dev/null | awk '{print $3}')
fi
if [ "$CURRENT_CRICTL_VERSION" != "$CRICTL_VERSION" ]; then
    echo "[setup] crictl is '${CURRENT_CRICTL_VERSION:-not installed}', pinned version is $CRICTL_VERSION -- (re)installing..."
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
else
    echo "[setup] crictl $CURRENT_CRICTL_VERSION already matches the pinned $CRICTL_VERSION, skipping install."
fi
command -v crictl
crictl --version

echo "[setup] pointing crictl explicitly at the CRI-O socket..."
cat <<EOF | sudo tee /etc/crictl.yaml > /dev/null
runtime-endpoint: unix:///var/run/crio/crio.sock
image-endpoint: unix:///var/run/crio/crio.sock
timeout: 10
debug: false
EOF

echo "[setup] forcing the cgroupfs cgroup manager..."
echo "[setup] (sidesteps the systemd-driver requirement that cgroup_parent be"
echo "[setup]  set to a valid slice name in pod-config.json -- the minimal"
echo "[setup]  pod-config used by this case, matching crictl's own docs"
echo "[setup]  example, leaves cgroup_parent unset)"
sudo mkdir -p /etc/crio/crio.conf.d
cat <<EOF | sudo tee /etc/crio/crio.conf.d/01-cgroup-manager.conf > /dev/null
[crio.runtime]
cgroup_manager = "cgroupfs"
EOF

echo "[setup] enabling the default CNI bridge plugin (ships disabled)..."
if [ -f /etc/cni/net.d/10-crio-bridge.conflist.disabled ]; then
    sudo mv /etc/cni/net.d/10-crio-bridge.conflist.disabled /etc/cni/net.d/10-crio-bridge.conflist
fi

echo "[setup] working around a systemd-networkd vs CNI bridge-plugin MAC"
echo "[setup] conflict: systemd's default MACAddressPolicy=persistent for"
echo "[setup] virtual NICs reassigns a freshly-created veth's MAC right after"
echo "[setup] the CNI bridge plugin sets it, before CRI-O reads it back --"
echo "[setup] this causes a deterministic 'Interface vethXXX Mac doesn't"
echo "[setup] match ... not found' failure on EVERY RunPodSandbox call, on"
echo "[setup] any host where systemd-networkd (not NetworkManager) manages"
echo "[setup] networking. Only applies when systemd-networkd is active."
if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    if [ ! -f /etc/systemd/network/98-cni-veth.link ]; then
        echo "[setup] systemd-networkd is active -- installing a udev .link rule so"
        echo "[setup] CNI-created veth* interfaces keep the MAC CNI assigned them..."
        cat <<'EOF' | sudo tee /etc/systemd/network/98-cni-veth.link > /dev/null
[Match]
OriginalName=veth*

[Link]
MACAddressPolicy=none
EOF
        sudo udevadm control --reload
    else
        echo "[setup] .link rule already present, skipping."
    fi
else
    echo "[setup] systemd-networkd is not the active network manager, skipping"
    echo "[setup] (this workaround is specific to that manager)."
fi

echo "[setup] (re)starting crio.service so the config above takes effect..."
sudo systemctl enable crio.service >/dev/null 2>&1 || true
sudo systemctl restart crio.service
sleep 2
sudo systemctl is-active crio.service


echo "[setup] ensuring Podman, gcc, strace, curl, tar and python3 are installed (Podman shares /var/lib/containers/storage with CRI-O; strace is the oracle's witness of what the program runs)..."
PKGS=""
for b in podman gcc strace curl tar python3; do command -v "$b" >/dev/null 2>&1 || PKGS="$PKGS $b"; done
if [ -n "$PKGS" ]; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" $PKGS
fi
for b in podman gcc strace curl tar python3 sha256sum; do command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }; done
podman --version

LIB_BASE="/var/lib/$CASE_ID"          # bin/go (the Go of this lab), app (the engineer's Go program)
CTL_DIR="$LIB_BASE/bin"
APP_DIR="$LIB_BASE/app"               # owned by the user who runs the setup
CACHE="/var/cache/$CASE_ID"           # the downloaded and checked Go toolchain (kept by cleanup.sh)
REG_CONF="/etc/containers/registries.conf.d/99-$CASE_ID.conf"
IMG="registry.$CASE_ID.invalid/shop/app:1.0"

# the Go of the machine is not used (Ubuntu 22.04 ships 1.18, too old for these modules, and a Go older than 1.21 cannot fetch a newer toolchain itself):
# setup installs this release next to the other pinned downloads and writes the wrapper $CTL_DIR/go for it
GO_VERSION="1.24.7"
case "$(uname -m)" in
    x86_64)        GO_ARCH="amd64" ;;
    aarch64|arm64) GO_ARCH="arm64" ;;
    *)             GO_ARCH="" ;;
esac
GO_ASSET="go$GO_VERSION.linux-$GO_ARCH.tar.gz"
GO_ROOT="$CACHE/go$GO_VERSION-$GO_ARCH"
[ -n "$GO_ARCH" ] || { echo "[setup] ERROR: no Go toolchain is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
echo "  host: $(crio --version | head -1), $(podman --version), $(uname -m), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (pods, images, files made for or by it)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/warm"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo mkdir -p "$CACHE" "$CTL_DIR"
sudo mkdir -p "$APP_DIR" && sudo chown "$(id -u):$(id -g)" "$APP_DIR"

echo "[setup] Go $GO_VERSION (the case's own toolchain, not the one of the machine): from the cache $CACHE, else downloaded and checked against the sha256 published by the Go project..."
if ! sudo test -x "$GO_ROOT/bin/go"; then
    if [ -n "${BENCH71499683_GO_TGZ:-}" ]; then cp "$BENCH71499683_GO_TGZ" "$WORK_DIR/gotgz"
    else
        for base in https://dl.google.com/go https://go.dev/dl; do
            curl -fsSL --retry 3 --max-time 900 -o "$WORK_DIR/gotgz" "$base/$GO_ASSET" && break
        done
        [ -s "$WORK_DIR/gotgz" ] || { echo "[setup] ERROR: could not download Go $GO_VERSION ($GO_ASSET from dl.google.com or go.dev)"; exit 1; }
        GO_SHA="${BENCH71499683_GO_SHA256:-}"
        [ -n "$GO_SHA" ] || GO_SHA="$(curl -fsSL --retry 3 --max-time 60 "https://dl.google.com/go/$GO_ASSET.sha256" | awk 'NR==1{print $1}')"
        echo "$GO_SHA" | grep -Eq '^[0-9a-f]{64}$' || { echo "[setup] ERROR: no sha256 for $GO_ASSET could be read (set BENCH71499683_GO_SHA256)"; exit 1; }
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
# the build tags leave out the parts of the libraries that need C headers the machine may not have (gpgme, btrfs, devicemapper)
sudo tee "$CTL_DIR/go" >/dev/null <<EOF
#!/bin/sh
# go $GO_VERSION of this lab (the go of the machine is not used); it never fetches another toolchain and builds without the gpgme, btrfs and devicemapper parts of the libraries
GOROOT="$GO_ROOT"; GOTOOLCHAIN=local; PATH="\$GOROOT/bin:\$PATH"
GOFLAGS="-mod=mod -tags=containers_image_openpgp,exclude_graphdriver_btrfs,exclude_graphdriver_devicemapper"
export GOROOT GOTOOLCHAIN PATH GOFLAGS
exec "\$GOROOT/bin/go" "\$@"
EOF
sudo chmod 755 "$CTL_DIR/go"
echo "  -> $("$CTL_DIR/go" version)"

echo "[setup] the registry of the image is blocked by configuration (it does not exist anyway: .invalid never resolves)..."
sudo mkdir -p "$(dirname "$REG_CONF")"
sudo tee "$REG_CONF" >/dev/null <<EOF
[[registry]]
location = "registry.$CASE_ID.invalid"
blocked = true
EOF

echo "[setup] the tools that build the image: a static program (sha256 of a file) and the generator of the image archives..."
cat > "$WORK_DIR/hasher.c" <<'CEOF'
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

/* hasher make IN OUT: writes the sha256 of IN, as 64 hex digits and a newline, to OUT */
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
    fprintf(stderr, "usage: hasher make IN OUT\n");
    return 2;
}
CEOF
gcc -static -Os -s -w -o "$WORK_DIR/hasher" "$WORK_DIR/hasher.c"
sudo install -m 755 "$WORK_DIR/hasher" "$STATE_DIR/hasher.keep"

# mkimage.py NAME OUT.tar HASHER: a docker-archive of an image of two layers (1: /hasher, 2: /data/unique.bin with random content and /data/label.txt) whose entrypoint prints the sha256 of the unique file
# (prints the truth about the image as JSON). The oracle uses it for a second, new image.
sudo tee "$STATE_DIR/mkimage.py" >/dev/null <<'PEOF'
import hashlib, io, json, os, platform, sys, tarfile

name, out, hasher = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[platform.machine()]
unique = os.urandom(4096)
label = ("bench71499683 %s\n" % os.urandom(8).hex()).encode()


def layer(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for path, data, mode in entries:
            ti = tarfile.TarInfo(path)
            ti.mtime = 0
            ti.mode = mode
            if data is None:
                ti.type = tarfile.DIRTYPE
                t.addfile(ti)
            else:
                ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


l1 = layer([("hasher", open(hasher, "rb").read(), 0o755)])
l2 = layer([("data/", None, 0o755), ("data/unique.bin", unique, 0o644), ("data/label.txt", label, 0o644)])
diff_ids = ["sha256:" + hashlib.sha256(x).hexdigest() for x in (l1, l2)]
cfg = json.dumps({
    "created": "2024-01-01T00:00:00Z", "architecture": arch, "os": "linux",
    "config": {"Entrypoint": ["/hasher", "make", "/data/unique.bin", "/dev/stdout"], "Env": ["PATH=/"]},
    "rootfs": {"type": "layers", "diff_ids": diff_ids},
    "history": [{"created_by": "bench71499683 hasher"}, {"created_by": "bench71499683 data"}],
}, sort_keys=True).encode()
cfg_id = hashlib.sha256(cfg).hexdigest()
ids = [d.split(":")[1] for d in diff_ids]
manifest = json.dumps([{"Config": cfg_id + ".json", "RepoTags": [name], "Layers": [i + "/layer.tar" for i in ids]}]).encode()
with tarfile.open(out, "w") as t:
    for path, data in [(cfg_id + ".json", cfg), (ids[0] + "/layer.tar", l1), (ids[1] + "/layer.tar", l2), ("manifest.json", manifest)]:
        ti = tarfile.TarInfo(path)
        ti.size = len(data)
        t.addfile(ti, io.BytesIO(data))
print(json.dumps({"name": name, "image_id": cfg_id, "diff_ids": diff_ids, "architecture": arch, "entrypoint": ["/hasher", "make", "/data/unique.bin", "/dev/stdout"],
                  "unique_sha": hashlib.sha256(unique).hexdigest(), "unique_path": "data/unique.bin"}))
PEOF

echo "[setup] recording the images CRI-O and Podman have now, then putting the image $IMG into the store of CRI-O (the archive it comes from is deleted at once)..."
sudo sh -c "crictl images -q --no-trunc 2>/dev/null | sed 's/^sha256://' | sort -u > \"$STATE_DIR/images.base\""
sudo python3 "$STATE_DIR/mkimage.py" "$IMG" "$STATE_DIR/a.tar" "$STATE_DIR/hasher.keep" | sudo tee "$STATE_DIR/truth.json" >/dev/null
sudo podman load -i "$STATE_DIR/a.tar" >/dev/null
sudo rm -f "$STATE_DIR/a.tar"
IMAGE_ID="$(sudo python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["image_id"])' "$STATE_DIR/truth.json")"
[ "$(sudo crictl inspecti "$IMG" | python3 -c 'import sys, json; print(json.load(sys.stdin)["status"]["id"])')" = "$IMAGE_ID" ] \
    || { echo "[setup] ERROR: CRI-O does not hold $IMG with the ID $IMAGE_ID"; exit 1; }
CRIO_ROOT="$(sudo crio config 2>/dev/null | sed -n 's/^root = "\(.*\)"/\1/p' | head -1)"
CRIO_DRIVER="$(sudo crio config 2>/dev/null | sed -n 's/^storage_driver = "\(.*\)"/\1/p' | head -1)"
echo "  -> $IMG is image $IMAGE_ID in the storage of CRI-O (root ${CRIO_ROOT:-?}, driver ${CRIO_DRIVER:-?})"
{
    echo "IMG=$IMG"
    echo "IMAGE_ID=$IMAGE_ID"
    echo "CRIO_ROOT='$CRIO_ROOT'"
    echo "CRIO_DRIVER='$CRIO_DRIVER'"
} | sudo tee "$STATE_DIR/truth.env" >/dev/null

# The program of the engineer: it opens the storage of CRI-O through the libraries CRI-O itself is made of (containers/image, containers/storage), finds the image and prints its ID.
# It exports nothing yet. go.mod pins the library versions of CRI-O 1.34.
echo "[setup] the engineer's Go program $APP_DIR (main.go, go.mod): it finds the image in the storage and exports nothing..."
cat > "$APP_DIR/go.mod" <<'CEOF'
module bench71499683/app

go 1.23.0

require (
	github.com/containers/image/v5 v5.36.2
	github.com/containers/storage v1.59.1
)
CEOF
cat > "$APP_DIR/main.go" <<'CEOF'
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/containers/image/v5/transports/alltransports"
	"github.com/containers/image/v5/types"
)

func main() {
	image := flag.String("image", "", "name of the image in the storage of CRI-O, as 'crictl images' shows it")
	out := flag.String("out", "", "archive file to write (it must not exist yet)")
	flag.Parse()
	if *image == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "usage: app -image NAME -out FILE")
		os.Exit(2)
	}
	if err := run(*image, *out); err != nil {
		fmt.Fprintln(os.Stderr, "export:", err)
		os.Exit(1)
	}
}

func run(image, out string) error {
	ctx := context.Background()
	src, err := alltransports.ParseImageName("containers-storage:" + image)
	if err != nil {
		return err
	}
	img, err := src.NewImage(ctx, &types.SystemContext{})
	if err != nil {
		return err
	}
	defer img.Close()
	fmt.Println("found", image, "- config", img.ConfigInfo().Digest)
	return errors.New("not implemented: nothing is written to " + out)
}
CEOF

# the modules and the compiled packages of the libraries go into the caches of this user now, so that the build of the engineer's program (and of a solution) takes seconds;
# the program built here only holds the imports a build tool needs
echo "[setup] warming the Go module cache and the build cache (containers/image, containers/storage)..."
cp "$APP_DIR/go.mod" "$WORK_DIR/warm/go.mod"
cat > "$WORK_DIR/warm/main.go" <<'CEOF'
package main

import (
	_ "github.com/containers/image/v5/copy"
	_ "github.com/containers/image/v5/docker/archive"
	_ "github.com/containers/image/v5/manifest"
	_ "github.com/containers/image/v5/oci/archive"
	_ "github.com/containers/image/v5/signature"
	_ "github.com/containers/image/v5/storage"
	_ "github.com/containers/image/v5/transports/alltransports"
	_ "github.com/containers/image/v5/types"
	_ "github.com/containers/storage"
)

func main() {}
CEOF
( cd "$WORK_DIR/warm" && "$CTL_DIR/go" build -o warm . ) >"$WORK_DIR/warm.log" 2>&1 \
    || { echo "[setup] ERROR: the Go modules could not be fetched or built:"; tail -15 "$WORK_DIR/warm.log" | cut -c1-200; exit 1; }
( cd "$APP_DIR" && "$CTL_DIR/go" build -o "$WORK_DIR/starter" . ) >"$WORK_DIR/starter.log" 2>&1 \
    || { echo "[setup] ERROR: the engineer's program does not build:"; tail -15 "$WORK_DIR/starter.log" | cut -c1-200; exit 1; }
echo "  -> the program builds"

echo "[setup] recording what is true now (hashes of the files nobody may change)..."
sudo sh -c "cd / && sha256sum \"${CTL_DIR#/}/go\" \"${REG_CONF#/}\" \"${STATE_DIR#/}/mkimage.py\" \"${STATE_DIR#/}/hasher.keep\" > \"$STATE_DIR/files.sha\""

echo "[setup] removing the build inputs..."
rm -rf "$WORK_DIR/hasher.c" "$WORK_DIR/hasher" "$WORK_DIR/warm" "$WORK_DIR/warm.log" "$WORK_DIR/starter" "$WORK_DIR/starter.log"

echo "[setup] done. CRI-O holds the image $IMG (nothing else has its content), its registry is blocked, and the program in $APP_DIR exports nothing."
