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

WORK_DIR="/tmp/bench59161183"
STATE_DIR="$WORK_DIR/.bench"
TARBALL="$WORK_DIR/app.tar"
DOCKER_TAG="bench59161183/app:local"
POD_NAME="bench59161183-pod"
CONTAINER_NAME="bench59161183"

# --- CRI-O + crictl environment: identical to the one q65650082 uses (same
# --- pinned versions, same cgroupfs / CNI / systemd-networkd workarounds),
# --- so both CRI-O cases run on the same, already-proven base.
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

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] ensuring podman + skopeo are installed (the GIVEN tools for"
echo "[setup] moving an image between stores; the task is about which store"
echo "[setup] CRI-O reads from, not about whether these tools exist)..."
if ! command -v podman >/dev/null 2>&1 || ! command -v skopeo >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" podman skopeo
fi
command -v podman
command -v skopeo
sudo podman info >/dev/null

echo "[setup] ensuring gcc is available (only to compile the small fixed"
echo "[setup] long-running program that goes into the image, so the same"
echo "[setup] script works on x86_64 and arm64 hosts)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] making sure CRI-O already has its pause image, so starting a"
echo "[setup] pod later does not depend on a registry round trip..."
PAUSE_IMAGE=$(sudo crio config 2>/dev/null | awk -F'"' '/^[[:space:]]*pause_image[[:space:]]*=/ {print $2; exit}')
if [ -n "$PAUSE_IMAGE" ]; then
    sudo crictl pull "$PAUSE_IMAGE" >/dev/null 2>&1 \
        || echo "[setup] note: could not pull $PAUSE_IMAGE now (it may already be cached)"
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
cd "$WORK_DIR"

case "$(uname -m)" in
    x86_64|amd64)   IMG_ARCH="amd64" ;;
    aarch64|arm64)  IMG_ARCH="arm64" ;;
    armv7l|armhf)   IMG_ARCH="arm" ;;
    ppc64le)        IMG_ARCH="ppc64le" ;;
    s390x)          IMG_ARCH="s390x" ;;
    *)              IMG_ARCH="amd64" ;;
esac

echo "[setup] compiling the image's entrypoint: a static program that prints"
echo "[setup] a line containing a per-run random token once a second. The"
echo "[setup] token exists only inside this image, so seeing it in the"
echo "[setup] container's log proves the container runs THIS image."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(6))')
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <time.h>

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        puts("bench59161183-image-ok token=" TOKEN);
        fflush(stdout);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/bench-app" "$STATE_DIR/app.c"

echo "[setup] writing the tarball the way 'docker save' lays it out"
echo "[setup] (manifest.json + config blob + one layer), tagged $DOCKER_TAG..."
cat > "$STATE_DIR/mkimage.py" <<'PYEOF'
import hashlib
import io
import json
import sys
import tarfile

out, binary, tag, arch = sys.argv[1:5]

layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    data = open(binary, "rb").read()
    ti = tarfile.TarInfo("bench-app")
    ti.size, ti.mode, ti.mtime, ti.uid, ti.gid = len(data), 0o755, 0, 0, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": arch,
    "os": "linux",
    "created": "1970-01-01T00:00:00Z",
    "config": {"Entrypoint": ["/bench-app"], "WorkingDir": "/"},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench59161183"}],
}, sort_keys=True, separators=(",", ":")).encode()
image_id = hashlib.sha256(config).hexdigest()

manifest = json.dumps([{
    "Config": image_id + ".json",
    "RepoTags": [tag],
    "Layers": [diff_id + "/layer.tar"],
}]).encode()


def add(t, name, payload):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
    t.addfile(ti, io.BytesIO(payload))


with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff_id)
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
    t.addfile(d)
    add(t, diff_id + "/layer.tar", layer)
    add(t, image_id + ".json", config)
    add(t, "manifest.json", manifest)

# For an image imported into containers-storage (what CRI-O reads), the
# image ID is the sha256 of the config blob. Print it so the setup can record
# what the oracle must find later.
print(image_id)
PYEOF
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$TARBALL" "$STATE_DIR/bench-app" "$DOCKER_TAG" "$IMG_ARCH")
chmod 0644 "$TARBALL"

echo "$TOKEN" > "$STATE_DIR/token"
echo "$IMAGE_ID" > "$STATE_DIR/expected_image_id"
sha256sum "$TARBALL" | awk '{print $1}' > "$STATE_DIR/tarball.sha256"
echo "  -> tarball: $TARBALL ($(stat -c %s "$TARBALL") bytes), image id sha256:$IMAGE_ID"

echo "[setup] done. CRI-O is running, but it does NOT know the image: the"
echo "[setup] only copy is the 'docker save' style tarball $TARBALL, and"
echo "[setup] no pod/container named '$POD_NAME'/'$CONTAINER_NAME' exists."
