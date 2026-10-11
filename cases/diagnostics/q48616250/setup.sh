#!/bin/bash
set -e

CASE_ID="bench48616250"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files, logs and runtime state of the node's containerd and of Docker
LIB_BASE="/var/lib/$CASE_ID"          # their roots and the containerd config (not in /run: it is mounted noexec on many hosts)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
CDIR="$RUN_BASE/containerd"
CSOCK="$CDIR/containerd.sock"         # the ONE containerd of the node: Docker and the CRI plugin both use it
DSOCK="$RUN_BASE/docker.sock"         # the Docker daemon's socket
PAUSE_REF="$CASE_ID.local/pause:1"    # the sandbox ("pause") image of the pods

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking containerd, ctr, runc, dockerd, docker and python3 are installed (the runtimes under test and the usual tools)..."
for b in containerd ctr runc dockerd docker python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
dockerd --version
dockerd --help 2>&1 | grep -q -- '--feature' || { echo "[setup] ERROR: this dockerd has no --feature option: it cannot keep its images in containerd (needs Docker 24 or newer)"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] ensuring crictl is installed (the CRI client; same pinned version as the other containerd cases)..."
if ! command -v crictl >/dev/null 2>&1; then
    echo "[setup] crictl not found, downloading $CRICTL_VERSION..."
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
crictl --version

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE/exec" "$CDIR" "$LIB_BASE/containerd" "$LIB_BASE/docker" "$LIB_BASE/etc"
cp "$CASE_DIR"/helpers/{app.c,mkimg.py,patch_config.py,lab.py,verify.py} "$STATE_DIR/"
sha256sum "$STATE_DIR"/app.c "$STATE_DIR"/mkimg.py "$STATE_DIR"/patch_config.py "$STATE_DIR"/lab.py "$STATE_DIR"/verify.py | awk '{print $1}' > "$STATE_DIR/helpers.sha"
cd "$WORK_DIR"

echo "[setup] the workload: a static program (serve waits for ever, attr prints and exits) in one-layer images, as archives that 'docker load' and 'ctr images import' take..."
gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
python3 "$STATE_DIR/mkimg.py" bench/app:1 "$STATE_DIR/app" "$STATE_DIR/app.tar" > /dev/null
python3 "$STATE_DIR/mkimg.py" "$PAUSE_REF" "$STATE_DIR/app" "$STATE_DIR/pause.tar" > /dev/null
chmod 0644 "$STATE_DIR"/*.tar

echo "[setup] the node's containerd (CRI plugin on, local sandbox image, own socket $CSOCK, own root and state)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$CDIR" "$CSOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    | sudo tee "$LIB_BASE/etc/config.toml" >/dev/null
sudo grep -q "$PAUSE_REF" "$LIB_BASE/etc/config.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$LIB_BASE/etc/config.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
CRI=(sudo crictl --runtime-endpoint "unix://$CSOCK" --image-endpoint "unix://$CSOCK" --timeout 60s)
UP=""
for _ in $(seq 1 80); do
    if [ -S "$CSOCK" ] && "${CRI[@]}" version >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: the node's containerd did not come up:"; sudo tail -5 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] importing the images for the CRI into the namespace k8s.io (the sandbox image and the image of the workload)..."
for t in pause app; do
    sudo ctr -a "$CSOCK" -n k8s.io images import "$STATE_DIR/$t.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $t.tar"; exit 1; }
done
for ref in "$PAUSE_REF" docker.io/bench/app:1; do
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "$ref" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know $ref"; exit 1; }
done

echo "[setup] starting Docker (socket $DSOCK, on the same containerd, images in containerd, no bridge network)..."
BASH_BIN=$(command -v bash); SETSID=$(command -v setsid); DOCKERD=$(command -v dockerd)
sudo "$SETSID" -f "$BASH_BIN" -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
    _ "$RUN_BASE/dockerd.pid" "$RUN_BASE/dockerd.log" \
    "$DOCKERD" --host "unix://$DSOCK" --pidfile "$RUN_BASE/docker.pid" --group "$(id -gn)" \
        --data-root "$LIB_BASE/docker" --exec-root "$RUN_BASE/exec" --containerd "$CSOCK" --feature containerd-snapshotter=true \
        --bridge none --iptables=false --ip6tables=false --ip-forward=false </dev/null >/dev/null 2>&1
UP=""
for _ in $(seq 1 120); do
    if docker -H "unix://$DSOCK" info >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: dockerd did not come up:"; sudo tail -8 "$RUN_BASE/dockerd.log" | cut -c1-400; exit 1; }

echo "[setup] Docker's containers (namespace moby) and the CRI pod with its containers (namespace k8s.io), some running and one of each exited..."
python3 "$STATE_DIR/lab.py" up "$DSOCK" "$CSOCK" "$WORK_DIR" || { echo "[setup] ERROR: the workloads were not created"; sudo tail -5 "$RUN_BASE/dockerd.log" | cut -c1-300; exit 1; }

echo "[setup] removing the build inputs the solution has no business with (the program, the images)..."
rm -f "$STATE_DIR/app" "$STATE_DIR"/*.tar

echo "[setup] done. One containerd ($CSOCK) is shared by Docker ($DSOCK) and the CRI plugin; there is no list-containers.sh."
