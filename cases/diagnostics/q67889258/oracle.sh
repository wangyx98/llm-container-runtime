#!/bin/bash
# Oracle: the node's containerd runs again with what it knew, and nothing was rebuilt to get there. Everything is measured here, not taken from what the solution says:
#  - the lab's files (the node's programs, the tools, containerd.toml, the image archive) are unchanged and the running containerd is the node's v1.6.17 on its original root;
#  - the broken meta.db is kept as evidence: a file in the evidence directory has the recorded sha256;
#  - the original records: the image under its name with the recorded manifest digest; c1 with the recorded creation time, image and bench.token label; c1's writable snapshot is active;
#  - the workload: the task of c1 is (re)started from the stored container, writes /beat with the token of c1 (the counter grows) and the /marker it wrote before the accident is still there;
#  - the repair holds: after a restart of the node's containerd the same records are there.
# Only the last transaction before the failure may be gone (e.g. a label on c1): nothing is required of it.

CASE_ID="bench67889258"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
NODEBIN="$LIB/node/bin"
SOCK="$RUN/containerd.sock"
NS="bench"
IMAGE="$CASE_ID.local/app:1"
ROOTFS="$RUN/containerd/io.containerd.runtime.v2.task/$NS/c1/rootfs"
fail() { echo "[oracle] FAIL: $*"; exit 1; }
ctr() { sudo timeout -k 3 60 "$NODEBIN/ctr" -a "$SOCK" -n "$NS" "$@"; }
stop_task() { ctr t kill -s KILL c1 >/dev/null 2>&1; for _ in $(seq 20); do ctr t ls 2>/dev/null | grep -q '^c1 ' || break; ctr t delete c1 >/dev/null 2>&1; sleep 0.5; done; }
trap 'stop_task' EXIT

check_records() {   # $1 = when
    [ "$(ctr images ls | awk 'NR>1 {print $1, $3}' | sort)" = "$(sudo cat "$STATE_DIR/images.before")" ] || fail "$1: the image (name, digest) is not the original"
    ctr content ls 2>/dev/null | grep -q "$(sudo cat "$STATE_DIR/manifest.digest")" || fail "$1: the manifest is not in the content store"
    [ "$(ctr c info c1 2>/dev/null | python3 -c "import json,sys; i=json.load(sys.stdin); print(i['CreatedAt']); print(i['Image']); print(i['Labels'].get('bench.token'))" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/c1.before")" ] || fail "$1: c1 is not the original container (creation time, image, bench.token)"
    ctr snapshots ls 2>/dev/null | awk '$1=="c1" {print $3}' | grep -qx Active || fail "$1: the snapshot c1 is not active"
}

echo "[oracle] the lab's files, the node's containerd and the evidence..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$NODEBIN/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
sudo tr '\0' ' ' < "/proc/$CPID/cmdline" | grep -qF "$LIB/etc/containerd.toml" || fail "the node's containerd does not use the lab's configuration"
ctr version 2>/dev/null | grep -q "v1.6.17" || fail "the node's containerd is not v1.6.17"
found=0
for f in $(sudo find "$LIB/evidence" -type f 2>/dev/null); do
    [ "$(sudo sha256sum "$f" | cut -d' ' -f1)" = "$(sudo cat "$STATE_DIR/corrupt.sha")" ] && found=1
done
[ "$found" = 1 ] || fail "no copy of the broken meta.db (recorded sha256) in $LIB/evidence"

echo "[oracle] the original image, container and snapshot..."
check_records "after the repair"

echo "[oracle] the workload: the task of c1 starts and writes /beat; the /marker is still there..."
stop_task
TOKEN=$(sudo cat "$STATE_DIR/token")
ctr t start -d c1 >/dev/null 2>&1 || fail "the task of c1 does not start"
b1=""
for _ in $(seq 30); do b1=$(sudo cat "$ROOTFS/beat" 2>/dev/null); [ -n "$b1" ] && break; sleep 0.5; done
sleep 2.5
b2=$(sudo cat "$ROOTFS/beat" 2>/dev/null)
[ "${b1#* }" = "$TOKEN" ] && [ "${b2#* }" = "$TOKEN" ] && [ "${b2%% *}" -gt "${b1%% *}" ] 2>/dev/null || fail "c1 does not write /beat with its token (got '$b1' / '$b2')"
[ "$(sudo cat "$ROOTFS/marker" 2>/dev/null)" = "$TOKEN" ] || fail "the /marker of c1 written before the accident is gone"
stop_task

echo "[oracle] the repair holds after a restart of the node's containerd..."
sudo timeout -k 3 120 "$LIB/bin/nodectl" restart >/dev/null 2>&1 || fail "the node's containerd does not restart"
check_records "after a restart"
echo "[oracle] PASS: the node runs again with the original image, c1 and its snapshot; the broken meta.db is kept."
