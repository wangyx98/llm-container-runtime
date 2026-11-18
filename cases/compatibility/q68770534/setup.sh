#!/bin/bash
set -e

# Ubuntu 22.04/24.04 ship `needrestart`, which pops up an interactive
# whiptail dialog whenever apt upgrades a shared library as a dependency.
# Force both apt's own prompts and needrestart into non-interactive mode
# (same workaround used by the other cases in this benchmark).
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CRICTL_VERSION="v1.34.0"

CASE_ID="bench68770534"
RUN_BASE="/run/$CASE_ID"              # socket + runtime state of the node
LIB_BASE="/var/lib/$CASE_ID"          # image store / snapshots of the node
SOCK="$RUN_BASE/containerd.sock"

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
POD_CONFIG="$WORK_DIR/pod-config.json"
CONTAINER_CONFIG="$WORK_DIR/container-config.json"
APP_REF="docker.io/nvidia/cuda:11.0-base"   # the full name of the thread
BARE_REF="cuda"                             # the short name of the thread
PAUSE_TAG="$CASE_ID-pause:latest"
PAUSE_REF="docker.io/library/$PAUSE_TAG"
POD_NAME="$CASE_ID-pod"
CONTAINER_NAME="$CASE_ID"

# crictl against the node, explicit endpoints (not what /etc/crictl.yaml says)
crictl_at() {
    sudo crictl --runtime-endpoint "unix://$SOCK" --image-endpoint "unix://$SOCK" --timeout 30s "$@"
}

echo "[setup] checking containerd, runc and the ctr client are installed (the"
echo "[setup] runtime under test; same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
containerd --version

echo "[setup] ensuring crictl is installed (CRI client for containerd)..."
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    armv7l|armhf)   CRICTL_ARCH="arm" ;;
    ppc64le)        CRICTL_ARCH="ppc64le" ;;
    s390x)          CRICTL_ARCH="s390x" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac
if ! command -v crictl >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl ca-certificates
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
command -v crictl
crictl --version

echo "[setup] ensuring gcc is available (only to compile two tiny static"
echo "[setup] programs that go into the images, so the same script works on"
echo "[setup] x86_64 and arm64 hosts and needs no registry)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/logs"
cd "$WORK_DIR"

case "$(uname -m)" in
    x86_64|amd64)   IMG_ARCH="amd64" ;;
    aarch64|arm64)  IMG_ARCH="arm64" ;;
    armv7l|armhf)   IMG_ARCH="arm" ;;
    ppc64le)        IMG_ARCH="ppc64le" ;;
    s390x)          IMG_ARCH="s390x" ;;
    *)              IMG_ARCH="amd64" ;;
esac

echo "[setup] compiling the two programs: the application (prints a line with a"
echo "[setup] per-run random token once a second; the token exists only inside"
echo "[setup] this image, so seeing it in a container's log proves the container"
echo "[setup] runs THIS image) and a minimal pause program for the pod sandboxes"
echo "[setup] (so starting a pod never has to download the usual pause image)..."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(6))')
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <time.h>

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        puts("bench68770534-image-ok token=" TOKEN);
        fflush(stdout);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

static void bye(int sig) { (void)sig; _exit(0); }

int main(void) {
    signal(SIGINT, bye);
    signal(SIGTERM, bye);
    for (;;) pause();
}
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/bench-app" "$STATE_DIR/app.c"
gcc -static -Os -s -o "$STATE_DIR/bench-pause" "$STATE_DIR/pause.c"

echo "[setup] writing both images the way 'docker save' lays them out"
echo "[setup] (manifest.json + config blob + one layer)..."
cat > "$STATE_DIR/mkimage.py" <<'PYEOF'
import hashlib
import io
import json
import sys
import tarfile

out, binary, name, tag, arch = sys.argv[1:6]

layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    data = open(binary, "rb").read()
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.mtime, ti.uid, ti.gid = len(data), 0o755, 0, 0, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": arch,
    "os": "linux",
    "created": "1970-01-01T00:00:00Z",
    "config": {"Entrypoint": ["/" + name], "WorkingDir": "/"},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
    "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench68770534"}],
}, sort_keys=True, separators=(",", ":")).encode()
image_id = hashlib.sha256(config).hexdigest()

manifest = json.dumps([{
    "Config": image_id + ".json",
    "RepoTags": [tag],
    "Layers": [diff_id + "/layer.tar"],
}]).encode()


def add(t, fname, payload):
    ti = tarfile.TarInfo(fname)
    ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
    t.addfile(ti, io.BytesIO(payload))


with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff_id)
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
    t.addfile(d)
    add(t, diff_id + "/layer.tar", layer)
    add(t, image_id + ".json", config)
    add(t, "manifest.json", manifest)

# An image's ID, as the CRI reports it, is the sha256 of its config blob.
# Print it so setup can record what the oracle must find later.
print(image_id)
PYEOF
IMAGE_ID=$(python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/app.tar" "$STATE_DIR/bench-app" bench-app "$APP_REF" "$IMG_ARCH")
python3 "$STATE_DIR/mkimage.py" "$STATE_DIR/pause.tar" "$STATE_DIR/bench-pause" bench-pause "$PAUSE_TAG" "$IMG_ARCH" >/dev/null
chmod 0644 "$STATE_DIR/app.tar" "$STATE_DIR/pause.tar"
echo "$TOKEN" > "$STATE_DIR/token"
echo "$IMAGE_ID" > "$STATE_DIR/expected_image_id"
echo "  -> application image id sha256:$IMAGE_ID"

echo "[setup] preparing a config generator: each node gets containerd's own"
echo "[setup] default config for the installed version, moved into a private"
echo "[setup] root/state/socket, with the sandbox image pointed at the local pause"
echo "[setup] image, NRI switched off (it would listen on one shared socket) and"
echo "[setup] restrict_oom_score_adj on (no CAP_SYS_RESOURCE needed)..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock, pause_ref = sys.argv[1:5]
section = ""
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}'\n"
    elif (section == "grpc" or "server.v1.grpc" in section) and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif (section == "ttrpc" or "server.v1.ttrpc" in section) and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif k in ("sandbox", "sandbox_image"):
        line = f"{indent}{k} = '{pause_ref}'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        # do not require CAP_SYS_RESOURCE (absent in unprivileged or nested
        # environments such as LXC/Incus system containers)
        line = f"{indent}restrict_oom_score_adj = true\n"
    sys.stdout.write(line)
PYEOF

# the shims of the node's containerd keep runc state and shim sockets in the HOST's /run/containerd (a path
# of the shim, not of the daemon): record what is there now, cleanup.sh removes only what is new
sudo mkdir -p "$LIB_BASE"
if [ -d /run/containerd ]; then
    sudo find /run/containerd/runc /run/containerd/s -mindepth 1 -maxdepth 2 2>/dev/null | sort | sudo tee "$LIB_BASE/hostrun.base" >/dev/null
else
    echo "NOEXIST" | sudo tee "$LIB_BASE/hostrun.base" >/dev/null
fi

start_node() {
    sudo mkdir -p "$RUN_BASE" "$LIB_BASE/data"
    containerd config default \
        | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/data" "$RUN_BASE" "$SOCK" "$PAUSE_REF" \
        | sudo tee "$RUN_BASE/config.toml" >/dev/null
    # setsid + all three fds redirected: the daemon must outlive this script
    # and must not keep the harness's stdout/stderr pipes open
    sudo setsid -f bash -c 'echo $$ > "$1/containerd.pid"; exec containerd --config "$1/config.toml" >"$1/containerd.log" 2>&1 </dev/null' _ "$RUN_BASE" </dev/null >/dev/null 2>&1
    for _ in $(seq 1 40); do
        [ -S "$SOCK" ] && crictl_at info >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    echo "[setup] ERROR: the node's containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    return 1
}

echo "[setup] starting the node: a private containerd daemon (own socket, own image"
echo "[setup] store) standing in for the machine the pod is scheduled to..."
start_node
echo "  -> node: $SOCK"

echo "[setup] giving the node the local pause image (no registry needed)..."
sudo ctr -a "$SOCK" -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null

echo "[setup] loading the application image into the node's 'k8s.io' namespace (the one"
echo "[setup] the Kubernetes CRI looks at) under its full name $APP_REF, and giving"
echo "[setup] it the short name '$BARE_REF' too ('ctr images tag' stores the name as written,"
echo "[setup] without adding docker.io/library/ and :latest). 'ctr images ls' lists both,"
echo "[setup] like in the bug report..."
sudo ctr -a "$SOCK" -n k8s.io images import "$STATE_DIR/app.tar" >/dev/null
sudo ctr -a "$SOCK" -n k8s.io images tag "$APP_REF" "$BARE_REF" >/dev/null
sudo ctr -a "$SOCK" -n k8s.io images ls 2>/dev/null | awk 'NR>1 {print "  -> " $1 "  " $3}' | grep -E "cuda"

echo "[setup] pointing this host's crictl at the node. The current /etc/crictl.yaml is"
echo "[setup] saved first: cleanup.sh puts it back, so other cases are not left"
echo "[setup] with a crictl that points at a socket that no longer exists..."
sudo mkdir -p "$LIB_BASE"
if [ -f /etc/crictl.yaml ]; then
    sudo cp -p /etc/crictl.yaml "$LIB_BASE/crictl.yaml.orig"
else
    sudo touch "$LIB_BASE/crictl.yaml.absent"
fi
cat <<YEOF | sudo tee /etc/crictl.yaml > /dev/null
runtime-endpoint: unix://$SOCK
image-endpoint: unix://$SOCK
timeout: 30
debug: false
YEOF

echo "[setup] writing the workload: a pod sandbox config and a container config"
echo "[setup] whose image is the short name '$BARE_REF' (the manifest of the thread). The CRI never"
echo "[setup] pulls when a container is created in an existing sandbox, the same"
echo "[setup] as a Kubernetes pod with imagePullPolicy: Never..."
cat > "$POD_CONFIG" <<PEOF
{
  "metadata": {
    "name": "$POD_NAME",
    "namespace": "default",
    "attempt": 1,
    "uid": "bench68770534uid00000001"
  },
  "log_directory": "$WORK_DIR/logs",
  "linux": {
    "security_context": {
      "namespace_options": {
        "network": 2
      }
    }
  }
}
PEOF
cat > "$CONTAINER_CONFIG" <<CEOF2
{
  "metadata": {
    "name": "$CONTAINER_NAME"
  },
  "image": {
    "image": "$BARE_REF"
  },
  "log_path": "$CONTAINER_NAME.0.log",
  "linux": {}
}
CEOF2

echo "[setup] starting the pod sandbox (the 'scheduled' pod)..."
POD_ID=$(crictl_at runp "$POD_CONFIG")
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "  -> pod sandbox $POD_ID"

echo "[setup] trying to create the container in it (this is EXPECTED to fail: the CRI"
echo "[setup] does not find the image '$BARE_REF' although ctr lists it)..."
if crictl_at create "$POD_ID" "$CONTAINER_CONFIG" "$POD_CONFIG" > "$STATE_DIR/first_attempt.out" 2>&1; then
    echo "[setup] FAIL: container creation unexpectedly succeeded; the scenario is not broken"
    exit 1
fi
sed 's/^/  -> /' "$STATE_DIR/first_attempt.out" | tail -3

echo "[setup] recording the node's containerd (pid and start time) and the digest of the image..."
NPID=$(sudo cat "$RUN_BASE/containerd.pid")
sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$NPID/stat" > "$STATE_DIR/containerd_start"
echo "$NPID" > "$STATE_DIR/containerd_pid"
sudo ctr -a "$SOCK" -n k8s.io images ls 2>/dev/null | awk -v r="$APP_REF" '$1 == r {print $3}' > "$STATE_DIR/expected_digest"

echo "[setup] removing the build inputs: the only place the application image exists"
echo "[setup] is the node's store..."
rm -f "$STATE_DIR/app.tar" "$STATE_DIR/pause.tar" "$STATE_DIR/bench-app" "$STATE_DIR/bench-pause" \
      "$STATE_DIR/app.c" "$STATE_DIR/pause.c" "$STATE_DIR/mkimage.py" "$STATE_DIR/patch_config.py"

echo "[setup] done. 'ctr -n k8s.io images ls' lists '$BARE_REF' and '$APP_REF'; the node's CRI lists only"
echo "[setup] the full name, so the container in the Ready pod sandbox cannot be created from '$BARE_REF'."
