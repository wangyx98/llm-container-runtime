#!/bin/bash
set -e

CASE_ID="bench58642878"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the lab: the k3s binary, its wrappers, the unit's files (etc), the node's data-dir (k3s), the disk's backing file
DATA="$LIB/k3s"                              # the node's data-dir, as the unit's config.yaml has it
DISK="/mnt/$CASE_ID-disk"                    # the "external disk": a loop-backed ext4 file system, mounted here, empty
CACHE="/var/cache/$CASE_ID"                  # the downloaded k3s release (kept by cleanup, checked by sha256 at every setup)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
K3S_VERSION="v1.30.5+k3s1"
NODE="$CASE_ID"
PAUSE_REF="bench.local/pause:1"
SEED_REF="bench.local/seed:1"

case "$(uname -m)" in
    x86_64|amd64)  K3S_ASSET="k3s";       K3S_SHA="322fbdc904deb1bf2f7a4460c0ae616db3aea75b8aefe911286946cdb0893d95" ;;
    aarch64|arm64) K3S_ASSET="k3s-arm64"; K3S_SHA="da3b23dc736401259f2e5ada5c481f8302d4f8a55b6d580e1abecaf85e89f2ac" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, sudo, sha256sum, mkfs.ext4, losetup, gcc..."
for c in python3 curl sudo sha256sum mkfs.ext4 losetup findmnt; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
echo "  host: $(uname -m), kernel $(uname -r), user $(id -un)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking that no other k3s is on this machine (the node uses /run/k3s and the ports 6443, 10250)..."
if pgrep -x k3s-server >/dev/null 2>&1 || [ -e /run/k3s ] || ! python3 -c '
import socket, sys
for port in (6443, 10250):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
    except OSError:
        sys.exit(1)
    finally:
        s.close()
'; then
    echo "[setup] ERROR: another k3s (or something on 6443 / 10250, or /run/k3s) is here: this case needs them for itself"; exit 1
fi

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$LIB/bin" "$LIB/etc" "$LIB/log" "$DATA/agent/images" "$CACHE"
[ -e /etc/rancher ] || echo yes | sudo tee "$STATE_DIR/owns-etc-rancher" >/dev/null
[ -e /var/lib/rancher ] || echo yes | sudo tee "$STATE_DIR/owns-var-lib-rancher" >/dev/null

echo "[setup] the k3s $K3S_VERSION binary (sha256 checked)..."
if [ -n "${BENCH58642878_K3S_BIN:-}" ]; then    # for a machine where curl cannot be used by this user: a k3s file of this version
    echo "$K3S_SHA  $BENCH58642878_K3S_BIN" | sha256sum -c --quiet - || { echo "[setup] ERROR: BENCH58642878_K3S_BIN is not the pinned k3s"; exit 1; }
    sudo install -m 755 "$BENCH58642878_K3S_BIN" "$CACHE/$K3S_ASSET-$K3S_VERSION"
elif ! { [ -f "$CACHE/$K3S_ASSET-$K3S_VERSION" ] && echo "$K3S_SHA  $CACHE/$K3S_ASSET-$K3S_VERSION" | sha256sum -c --quiet - 2>/dev/null; }; then
    sudo rm -f "$CACHE/$K3S_ASSET-$K3S_VERSION"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/k3s.dl" "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/$K3S_ASSET" || { echo "[setup] ERROR: could not download k3s"; exit 1; }
    echo "$K3S_SHA  $WORK_DIR/k3s.dl" | sha256sum -c --quiet - || { echo "[setup] ERROR: k3s does not match its sha256"; exit 1; }
    sudo install -m 755 "$WORK_DIR/k3s.dl" "$CACHE/$K3S_ASSET-$K3S_VERSION"
    rm -f "$WORK_DIR/k3s.dl"
fi
sudo install -m 755 "$CACHE/$K3S_ASSET-$K3S_VERSION" "$LIB/bin/k3s.bin"

# `k3s` is the command of the question (`k3s ctr images import ...`); the real binary is k3s.bin. Every k3s command unpacks the program's tools (containerd, runc, ...) below
# /var/lib/rancher/k3s/data (the default place, whatever the node's data-dir is): /var/lib/rancher is removed again by cleanup when it was not there.
sudo tee "$LIB/bin/k3s" >/dev/null <<'K3S_WRAP_EOF'
#!/bin/sh
export KUBECONFIG=/var/lib/bench58642878/etc/kubeconfig
exec /var/lib/bench58642878/bin/k3s.bin "$@"
K3S_WRAP_EOF
sudo chmod 755 "$LIB/bin/k3s"

echo "[setup] the unit: k3sctl (start, stop, restart, status) and etc/config.yaml..."
sudo tee "$LIB/bin/k3sctl" >/dev/null <<'K3SCTL_EOF'
#!/bin/bash
# k3sctl start|stop|restart|status : this node's "systemd unit". `start` runs the real k3s with the fixed arguments below and the node's configuration file /var/lib/bench58642878/etc/config.yaml (the
# data-dir is set there); `stop` is what k3s-killall.sh does: k3s, its containerd, the shims and the containers' programs end, and what they mounted (overlay, tmpfs) is unmounted.
LIB=/var/lib/bench58642878
DISK=/mnt/bench58642878-disk
K3S="$LIB/bin/k3s.bin"
alive() { pgrep -f -- "^$K3S server" 2>/dev/null | head -1 | grep .; }
containerd_pids() {   # the containerd of k3s runs the program k3s unpacked: .../k3s/data/<hash>/bin/k3s
    for p in $(pgrep -x containerd 2>/dev/null); do case "$(readlink "/proc/$p/exe" 2>/dev/null)" in */k3s/data/*/bin/*) echo "$p" ;; esac; done
}
node_ready() {   # the kubelet answers through the API server (a node's Ready can be stale after a restart), the node is Ready and takes Pods
    [ "$("$LIB/bin/k3s" kubectl get --raw /api/v1/nodes/bench58642878/proxy/healthz 2>/dev/null)" = ok ] &&
    [ "$("$LIB/bin/k3s" kubectl get node bench58642878 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] &&
    ! "$LIB/bin/k3s" kubectl get node bench58642878 -o jsonpath='{.spec.taints}' 2>/dev/null | grep -q NoSchedule
}
case "$1" in
start)
    alive >/dev/null && { echo "k3sctl: already running"; exit 0; }
    mkdir -p "$LIB/log"
    setsid nohup "$K3S" server --config "$LIB/etc/config.yaml" --write-kubeconfig "$LIB/etc/kubeconfig" --write-kubeconfig-mode 0644 --node-name bench58642878 \
        --pause-image bench.local/pause:1 \
        --disable=coredns,servicelb,traefik,metrics-server,local-storage --disable-network-policy --disable-kube-proxy --flannel-backend=none --disable-helm-controller \
        --kubelet-arg=root-dir="$LIB/kubelet" --kubelet-arg=image-gc-high-threshold=100 --kubelet-arg=image-gc-low-threshold=99 \
        '--kubelet-arg=eviction-hard=nodefs.available<50Mi,imagefs.available<50Mi,nodefs.inodesFree<1%,imagefs.inodesFree<1%' \
        >> "$LIB/log/k3s.log" 2>&1 < /dev/null &
    gone=0
    for _ in $(seq 1 120); do
        sleep 2
        if alive >/dev/null; then gone=0; else gone=$((gone + 1)); fi    # k3s starts itself again from the tools it unpacks: a poll may fall between the two
        [ "$gone" -ge 3 ] && { echo "k3sctl: k3s ended, see $LIB/log/k3s.log"; tail -5 "$LIB/log/k3s.log"; exit 1; }
        node_ready && { echo "k3sctl: node ready"; exit 0; }
    done
    echo "k3sctl: the node did not become ready"; tail -5 "$LIB/log/k3s.log"; exit 1 ;;
stop)
    kids=""
    if pid=$(alive); then
        kids="$(pgrep -P "$pid") $(containerd_pids)"
        kill -TERM "$pid"
        for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -KILL "$pid" 2>/dev/null
    else
        kids="$(containerd_pids)"
    fi
    for sig in TERM KILL; do
        for p in $(pgrep -f -- "-address /run/k3s/containerd/containerd.sock" 2>/dev/null); do
            for c in $(pgrep -P "$p"); do kill -KILL "$c" 2>/dev/null; done
            kill "-$sig" "$p" 2>/dev/null
        done
        for p in $kids $(containerd_pids); do kill "-$sig" "$p" 2>/dev/null; done
        sleep 1
    done
    for _ in 1 2 3; do
        for m in $(findmnt -rn -t overlay,tmpfs -o TARGET | grep -E "^($LIB|/run/k3s|$DISK)/" | sort -r); do umount -l "$m" 2>/dev/null; done
    done
    echo "k3sctl: stopped" ;;
restart) "$0" stop && "$0" start ;;
status)
    if pid=$(alive); then echo "k3s running (pid $pid), containerd: $(containerd_pids | tr '\n' ' ')"; else echo "k3s not running"; exit 1; fi ;;
*) echo "usage: k3sctl start|stop|restart|status"; exit 2 ;;
esac
K3SCTL_EOF
sudo chmod 755 "$LIB/bin/k3sctl"
sudo tee "$LIB/etc/config.yaml" >/dev/null <<EOF2
# the node's configuration file (the unit reads it with --config; the other arguments are fixed in k3sctl)
data-dir: $DATA
EOF2

echo "[setup] programs and images (offline): app (prints its /salt and stays), pause..."
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
#include <stdio.h>
#include <unistd.h>
int main(void) {
    char b[128] = {0};
    FILE *f = fopen("/salt", "r");
    if (f) { size_t n = fread(b, 1, 127, f); b[n] = 0; fclose(f); }
    printf("salt=%s\n", b);
    fflush(stdout);
    for (;;) pause();
}
APP_C_EOF
sudo tee "$STATE_DIR/pause.c" >/dev/null <<'PAUSE_C_EOF'
#include <unistd.h>
int main(void) { for (;;) pause(); }
PAUSE_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
sudo gcc -static -Os -s -w -o "$STATE_DIR/pause" "$STATE_DIR/pause.c"
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUTFILE REF NAME BINARY SALT : an OCI archive with ONE layer (/NAME from the file BINARY, /salt with SALT, empty /tmp) whose entrypoint is /NAME."""
import hashlib
import io
import json
import platform
import sys
import tarfile

out, ref, name, binary, salt = sys.argv[1:6]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
T = 1700000000


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


entries = [("tmp/", None, 0o1777), (name, open(binary, "rb").read(), 0o755), ("salt", salt.encode(), 0o644)]
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for path, data, mode in entries:
        ti = tarfile.TarInfo(path)
        ti.mtime = T
        if data is None:
            ti.type, ti.mode = tarfile.DIRTYPE, mode
        else:
            ti.size, ti.mode = len(data), mode
        t.addfile(ti, io.BytesIO(data) if data is not None else None)
layer = buf.getvalue()
cfg = json.dumps({"architecture": arch, "os": "linux", "config": {"Entrypoint": ["/" + name]}, "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(cfg), "size": len(cfg)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(layer), "size": len(layer)}]}).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    for path, blob in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(cfg)[7:], cfg), ("blobs/sha256/" + sha(manifest)[7:], manifest),
                       ("blobs/sha256/" + sha(layer)[7:], layer)):
        ti = tarfile.TarInfo(path)
        ti.size, ti.mtime = len(blob), T
        t.addfile(ti, io.BytesIO(blob))
print(sha(manifest))
MKIMG_PY_EOF
SEED_SALT=$(python3 -c 'import secrets; print(secrets.token_hex(10))')
sudo python3 "$STATE_DIR/mkimg.py" "$DATA/agent/images/pause.tar" "$PAUSE_REF" pause "$STATE_DIR/pause" none >/dev/null
SEED_MANIFEST=$(sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/seed.tar" "$SEED_REF" app "$STATE_DIR/app" "$SEED_SALT")

echo "[setup] the node's configuration for a machine without CAP_SYS_RESOURCE (runc cannot lower oom_score_adj there)..."
CAPBND=$(awk '/^CapBnd/ {print $2}' /proc/self/status)
if [ $(( (0x$CAPBND >> 24) & 1 )) -eq 0 ]; then
    sudo tee "$LIB/etc/cri-restrict.toml" >/dev/null <<'CRI_EOF'
[plugins."io.containerd.grpc.v1.cri"]
  restrict_oom_score_adj = true
  stream_server_address = "127.0.0.1"
  stream_server_port = "10010"
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
  sandbox_image = "bench.local/pause:1"

[plugins."io.containerd.grpc.v1.cri".containerd]
  snapshotter = "overlayfs"
  disable_snapshot_annotations = true

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = false
CRI_EOF
    sudo install -d -m 755 "$DATA/agent/etc/containerd"
    printf 'imports = ["%s/etc/cri-restrict.toml"]\n{{ template "base" . }}\n' "$LIB" | sudo tee "$DATA/agent/etc/containerd/config.toml.tmpl" >/dev/null
    echo "  no CAP_SYS_RESOURCE here: config.toml.tmpl added (restrict_oom_score_adj)"
fi

echo "[setup] the external disk: a 1 GiB ext4 file system in a file, mounted at $DISK (empty)..."
sudo truncate -s 1G "$LIB/disk.img"
sudo mkfs.ext4 -q -F "$LIB/disk.img"
sudo install -d -m 755 "$DISK"
sudo mount -o loop "$LIB/disk.img" "$DISK"
[ "$(sudo findmnt -n -o SOURCE "$DISK" | cut -c1-9)" = "/dev/loop" ] || { echo "[setup] ERROR: the disk is not a loop mount"; exit 1; }

echo "[setup] starting the node (the first start unpacks k3s' tools and takes about a minute)..."
[ -e /run/k3s ] || echo yes | sudo tee "$STATE_DIR/owns-run-k3s" >/dev/null
sudo "$LIB/bin/k3sctl" start || { echo "[setup] ERROR: the node did not start"; exit 1; }

echo "[setup] the seed image and the seed Pod (hostNetwork, imagePullPolicy Never)..."
sudo "$LIB/bin/k3s" ctr images import "$STATE_DIR/seed.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the seed image"; exit 1; }
sudo tee "$STATE_DIR/seed-pod.yaml" >/dev/null <<SEED_POD_EOF
apiVersion: v1
kind: Pod
metadata: {name: b58642878-seed, namespace: default}
spec:
  hostNetwork: true
  terminationGracePeriodSeconds: 1
  containers:
  - {name: main, image: $SEED_REF, imagePullPolicy: Never}
SEED_POD_EOF
sudo "$LIB/bin/k3s" kubectl apply -f "$STATE_DIR/seed-pod.yaml" >/dev/null || { echo "[setup] ERROR: could not create the seed Pod"; exit 1; }
for _ in $(seq 1 60); do
    [ "$(sudo "$LIB/bin/k3s" kubectl get pod b58642878-seed -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && break
    sleep 2
done
[ "$(sudo "$LIB/bin/k3s" kubectl get pod b58642878-seed -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] || { echo "[setup] ERROR: the seed Pod does not run"; exit 1; }

echo "[setup] recording what is true (the oracle and the precondition check it)..."
POD_UID=$(sudo "$LIB/bin/k3s" kubectl get pod b58642878-seed -o jsonpath='{.metadata.uid}')
LAB_DEV=$(stat -c %d "$LIB")
DISK_DEV=$(stat -c %d "$DISK")
ORIG_ROOT=$(readlink -f "$DATA/agent/containerd")
sudo python3 - "$STATE_DIR/truth.json" "$SEED_SALT" "$SEED_MANIFEST" "$POD_UID" "$LAB_DEV" "$DISK_DEV" "$ORIG_ROOT" "$LIB/disk.img" <<'PY'
import json, sys
out, salt, manifest, uid, lab_dev, disk_dev, root, img = sys.argv[1:9]
json.dump({"seed_salt": salt, "seed_manifest": manifest, "seed_pod_uid": uid, "lab_dev": int(lab_dev), "disk_dev": int(disk_dev), "orig_root": root, "disk_img": img}, open(out, "w"))
PY
sudo sh -c "sha256sum '$LIB/bin/k3s.bin' '$LIB/bin/k3s' '$LIB/bin/k3sctl' '$STATE_DIR/app' '$STATE_DIR/mkimg.py' > '$STATE_DIR/lab.sha'; sha256sum '$DATA/agent/images/pause.tar' > '$STATE_DIR/pause.sha'"
sudo sh -c "sha256sum '$LIB/etc/config.yaml' > '$STATE_DIR/config.initial.sha'"
sudo sh -c "date +%s > '$STATE_DIR/ready'"
echo "[setup] done: node $NODE (k3sctl in $LIB/bin), data-dir $DATA, disk $DISK, seed Pod b58642878-seed"
