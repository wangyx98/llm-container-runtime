#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75533491"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ROOTFS="$STATE_DIR/rootfs"

echo "[setup] checking containerd, its ctr client and python3 are installed..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }
containerd --version
# The containers get no image: their user-land is the host's /usr (bind-mounted read-only) and
# /bin, /sbin, /lib, /lib64 are links into it, which needs a host whose /bin, /sbin and /lib are
# links to /usr/... (Ubuntu 20.04 and later, Debian 10 and later).
for d in bin sbin lib; do
    [ -L "/$d" ] || { echo "[setup] ERROR: /$d is not a link into /usr on this host (merged-/usr layout needed)"; exit 1; }
done
[ -x /usr/bin/sleep ] && [ -x /bin/sh ] || { echo "[setup] ERROR: sleep or sh missing on the host"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure containerd is running..."
# Do not restart it here: this case does not use the CRI, so the default config
# is not needed, and a benchmark run executes this setup once per sample.
if ! sudo ctr version >/dev/null 2>&1; then
    sudo systemctl reset-failed containerd 2>/dev/null || true   # clears a start-limit hit
    sudo systemctl start containerd
fi
for _ in $(seq 1 20); do
    [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo ctr version >/dev/null

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"

echo "[setup] building the root file system of the containers (empty directories and links into /usr)..."
mkdir -p "$ROOTFS"/{usr,proc,sys,dev,tmp,run,etc}
for d in bin sbin lib lib64 lib32 libx32; do
    [ -L "/$d" ] && ln -s "$(readlink "/$d")" "$ROOTFS/$d"
done
true

# helper files used by this script and by oracle.sh (the oracle makes one more container)
cat > "$STATE_DIR/mkspec.py" <<'PYEOF'
import json
import sys

# usage: mkspec.py TEMPLATE STYLE ID UUID  -> OCI spec on stdout
template, style, cid, uuid = sys.argv[1:5]
spec = json.load(open(template))
if style == "ctr_default":
    # what `ctr run` does: /<namespace>/<id>
    path = "/default/%s" % cid
elif style == "cgroupfs":
    # kubelet with the cgroupfs cgroup driver
    path = "/bench75533491/kubepods/burstable/pod%s/%s" % (uuid, cid)
elif style == "systemd":
    # kubelet with the systemd cgroup driver: slices and a cri-containerd-<id>.scope
    path = ("/bench75533491.slice/bench75533491-burstable.slice/"
            "bench75533491-burstable-pod%s.slice/cri-containerd-%s.scope" % (uuid.replace("-", "_"), cid))
else:
    sys.exit("unknown style " + style)
spec["linux"]["cgroupsPath"] = path
json.dump(spec, sys.stdout)
PYEOF

cat > "$STATE_DIR/lib.sh" <<'LIBEOF'
CASE_ID="bench75533491"
STATE_DIR="/tmp/bench75533491/.bench"

# make_container STYLE ID: create the container and start its task; returns 0 once it is RUNNING
make_container() {
    local style="$1" id="$2" uuid i
    uuid=$(python3 -c 'import uuid; print(uuid.uuid4())')
    python3 "$STATE_DIR/mkspec.py" "$STATE_DIR/spec_template.json" "$style" "$id" "$uuid" > "$STATE_DIR/spec_$id.json" || return 1
    sudo ctr -n default containers create --label "$CASE_ID=1" --config "$STATE_DIR/spec_$id.json" "$id" >/dev/null 2>&1 || return 1
    timeout -k 5 60 sudo ctr -n default tasks start -d "$id" </dev/null >/dev/null 2>&1 || return 1
    for i in $(seq 1 20); do
        if sudo ctr -n default tasks ls 2>/dev/null | awk -v n="$id" '$1==n && $3=="RUNNING"' | grep -q .; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# cexec ID SCRIPT: run SCRIPT with /bin/sh -c inside the container, as root, no terminal
cexec() {
    timeout -k 5 30 sudo ctr -n default tasks exec --exec-id "$CASE_ID-$RANDOM$RANDOM" "$1" /bin/sh -c "$2" </dev/null 2>/dev/null
}
LIBEOF

echo "[setup] taking the default OCI spec ctr writes for such a container (used as the template)..."
sudo ctr -n default containers create --label "$CASE_ID=1" --rootfs \
    --mount type=bind,src=/usr,dst=/usr,options=rbind:ro \
    "$ROOTFS" "$CASE_ID-spec-tmp" /usr/bin/sleep 3600 >/dev/null 2>&1
sudo ctr -n default containers info "$CASE_ID-spec-tmp" 2>/dev/null \
    | python3 -c 'import json,sys; json.dump(json.load(sys.stdin)["Spec"], open(sys.argv[1], "w"))' "$STATE_DIR/spec_template.json"
sudo ctr -n default containers delete "$CASE_ID-spec-tmp" >/dev/null 2>&1

# shellcheck disable=SC1091
. "$STATE_DIR/lib.sh"

echo "[setup] creating three running containers with random 64-hex IDs; their cgroup paths follow the"
echo "[setup] three layouts seen on containerd hosts..."
: > "$STATE_DIR/containers"
for style in ctr_default cgroupfs systemd; do
    id=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
    make_container "$style" "$id" || { echo "[setup] ERROR: could not start the $style container $id"; exit 1; }
    echo "$style $id" >> "$STATE_DIR/containers"
    echo "  -> $style ${id:0:12}..."
done

echo "[setup] done. Three containers run; $WORK_DIR/get_container_id.sh does not exist yet."
