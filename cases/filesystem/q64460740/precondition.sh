#!/bin/bash
set -e

CASE_ID="bench64460740"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_ROOT="$LIB_BASE/containerd"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
BLOBS_DIR="$T_ROOT/io.containerd.content.v1.content/blobs/sha256"
SNAP_DIR="$T_ROOT/io.containerd.snapshotter.v1.overlayfs/snapshots"
APP_REF="$CASE_ID.local/app:1"
JOB_REF="$CASE_ID.local/job:1"
UNUSED_REF="$CASE_ID.local/unused:1"
PAUSE_REF="$CASE_ID.local/pause:1"

CTR_T="sudo ctr -a $T_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
bytes() { sudo find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}'; }   # the bytes of the files below a directory
image_id() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"])' "$STATE_DIR/image_$1.json"; }   # sha256:<config digest> = the CRI's image id
APP_ID=$(st container_app); OLD_ID=$(st container_old); JOB_ID=$(st container_job); POD_ID=$(st pod_id); PID=$(st pid)

echo "[precondition] checking the node's containerd (the process of setup), its CRI, and that nothing was changed..."
for f in t.id pod_id container_app container_old container_job pid starttime t.metadb.inode config.sha blobs.keep blobs.go shared.digest payload.sha bytes.base pause-oracle.tar image_app.json image_job.json image_unused.json image_pause.json; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same t || fail "the node's containerd is not running"
[ "$(sudo sha256sum "$T_CFG" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the containerd config was changed"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer"
[ "$(sudo stat -c %i "$T_ROOT/io.containerd.metadata.v1.bolt/meta.db")" = "$(st t.metadb.inode)" ] || fail "the node's metadata database is not the recorded one"
echo "  -> OK"

echo "[precondition] checking the pod and its three containers: the pod ready, the workload RUNNING (host pid and start time as recorded, counting),"
echo "[precondition] the earlier run of the same image and the one-shot job EXITED with code 0, and no other container..."
[ "$("${CRI[@]}" pods -q | wc -l)" = 1 ] || fail "the node does not have exactly one pod sandbox"
[ "$("${CRI[@]}" inspectp -o go-template --template '{{.status.state}}' "$POD_ID" 2>/dev/null)" = "SANDBOX_READY" ] || fail "the pod sandbox is not ready"
[ "$("${CRI[@]}" ps -a -q | wc -l)" = 3 ] || fail "the node does not have exactly three containers"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the workload is not running"
for c in "$OLD_ID" "$JOB_ID"; do
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}} {{.status.exitCode}}' "$c" 2>/dev/null)" = "CONTAINER_EXITED 0" ] || fail "container $c has not exited with code 0"
done
[ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID")" = "$PID" ] || fail "the workload has another host pid"
[ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}')" = "$(st starttime)" ] || fail "the workload has another start time"
L1=$("${CRI[@]}" logs --tail=1 "$APP_ID" | tail -1); sleep 2; L2=$("${CRI[@]}" logs --tail=1 "$APP_ID" | tail -1)
B1=$(sed -n 's/.* beat=\([0-9]*\) .*/\1/p' <<<"$L1"); B2=$(sed -n 's/.* beat=\([0-9]*\) .*/\1/p' <<<"$L2")
[ -n "$B1" ] && [ "$B2" -gt "$B1" ] || fail "the workload's heartbeat does not advance ($L1 / $L2)"
echo "  -> OK ($L2)"

echo "[precondition] checking who uses which image: the running and the exited container use A, the job uses B, nothing uses C..."
for pair in "$APP_ID:app" "$OLD_ID:app" "$JOB_ID:job"; do
    c=${pair%%:*}; k=${pair##*:}
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.imageRef}}' "$c" 2>/dev/null)" = "$(image_id $k)" ] || fail "container $c does not use image $k"
done
for c in $("${CRI[@]}" ps -a -q); do
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.imageRef}}' "$c" 2>/dev/null)" != "$(image_id unused)" ] || fail "container $c uses the image that is supposed to be unused"
done
echo "  -> OK"

echo "[precondition] checking the four images: known to the CRI under their recorded ids, named in k8s.io, and A, B and C built on ONE shared"
echo "[precondition] base layer (the same layer digest first in each manifest, stored once)..."
[ "$("${CRI[@]}" images -q | wc -l)" = 4 ] || fail "the CRI does not list four images"
for pair in "$APP_REF:app" "$JOB_REF:job" "$UNUSED_REF:unused" "$PAUSE_REF:pause"; do
    r=${pair%:*}; k=${pair##*:}
    [ "$("${CRI[@]}" inspecti -o go-template --template '{{.status.id}}' "$r" 2>/dev/null)" = "$(image_id $k)" ] || fail "the CRI reports another id for $r"
    $CTR_T -n k8s.io images ls -q 2>/dev/null | grep -qxF "$r" || fail "$r is not an image of k8s.io"
done
SH=$(st shared.digest)
for k in app job unused; do
    M=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/image_$k.json")
    [ "$(sudo cat "$BLOBS_DIR/${M#sha256:}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["layers"][0]["digest"])')" = "$SH" ] || fail "the manifest of $k does not start with the shared layer"
done
echo "  -> OK (shared layer $SH)"

echo "[precondition] checking the disk: every blob of the four images is in the content store, and the stores hold what the images weigh"
echo "[precondition] (the content store and the snapshots, as recorded by setup)..."
cat "$STATE_DIR/blobs.keep" "$STATE_DIR/blobs.go" | while read -r d; do
    sudo test -f "$BLOBS_DIR/${d#sha256:}" || fail "the blob $d is not in the content store"
done
read -r CB SB < "$STATE_DIR/bytes.base"
CN=$(bytes "$BLOBS_DIR"); SN=$(bytes "$SNAP_DIR")
[ "$CN" -ge 22000000 ] && [ "$SN" -ge 22000000 ] || fail "the stores hold too little (content $CN, snapshots $SN bytes; 8+2+6+6 MiB expected)"
[ $((CN > CB ? CN - CB : CB - CN)) -lt 1000000 ] && [ $((SN > SB ? SN - SB : SB - SN)) -lt 1000000 ] || fail "the stores changed since setup (content $CB -> $CN, snapshots $SB -> $SN)"
echo "  -> OK (content store $CN bytes, snapshots $SN bytes)"

echo "[precondition] PASS - a node with a running workload, two finished containers and three images that share a layer; the data of the"
echo "[precondition]        two images that nothing needs takes 12 MiB in each of the stores."
