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

RECLAIM_MIN=11534336      # 11 MiB: the removed images B and C hold 2 x 6 MiB of their own in each of the two stores

echo "[oracle] check 0: the node's containerd is still the process of setup (not stopped, killed or restarted), its config is unchanged, it answers,"
echo "[oracle]          and its data directory is intact (the same metadata database: nothing was deleted behind the daemon's back)..."
alive_same t || fail "the node's containerd is not the process of setup (it was stopped, killed, restarted or replaced)"
[ "$(sudo sha256sum "$T_CFG" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the containerd config was changed"
for _ in $(seq 1 30); do "${CRI[@]}" version >/dev/null 2>&1 && break; sleep 1; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer"
[ "$(sudo stat -c %i "$T_ROOT/io.containerd.metadata.v1.bolt/meta.db" 2>/dev/null)" = "$(st t.metadb.inode)" ] || fail "the node's metadata database was deleted or replaced (the data directory of the running daemon was wiped)"
for d in io.containerd.content.v1.content io.containerd.snapshotter.v1.overlayfs; do
    sudo test -d "$T_ROOT/$d" || fail "the node's directory $d is gone (the data directory of the running daemon was wiped)"
done
echo "  -> OK"

echo "[oracle] check 1: the workload must be untouched: same container, still running, same process, heartbeat advancing, pod still ready..."
STATE=$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null || true)
[ -n "$STATE" ] || fail "the workload container $APP_ID does not exist any more (it was removed)"
[ "$STATE" = "CONTAINER_RUNNING" ] || fail "the workload container $APP_ID is not running (state $STATE): it was stopped"
NOW=$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null || true)
START=$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$NOW/stat" 2>/dev/null | awk '{print $20}')
if [ "$NOW" != "$PID" ] || [ "$START" != "$(st starttime)" ]; then
    fail "the workload process changed (host pid $PID before, ${NOW:-none} now): it was restarted"
fi
L1=$("${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | tail -1); sleep 2.5; L2=$("${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | tail -1)
B1=$(sed -n 's/.* beat=\([0-9]*\) .*/\1/p' <<<"$L1"); B2=$(sed -n 's/.* beat=\([0-9]*\) .*/\1/p' <<<"$L2")
[ -n "$B1" ] && [ -n "$B2" ] && [ "$B2" -gt "$B1" ] || fail "the workload's heartbeat does not advance ('$L1' -> '$L2')"
[ "$("${CRI[@]}" inspectp -o go-template --template '{{.status.state}}' "$POD_ID" 2>/dev/null)" = "SANDBOX_READY" ] || fail "the pod sandbox $POD_ID is not SANDBOX_READY any more"
echo "  -> OK (host pid $PID, beat $B1 -> $B2)"

echo "[oracle] check 2: the image the workload runs (A) must still be there, by name and by id..."
$CTR_T -n k8s.io images ls -q 2>/dev/null | grep -qxF "$APP_REF" || fail "$APP_REF is not listed in namespace k8s.io any more: the image of the running workload was removed"
GOT=$("${CRI[@]}" inspecti -o go-template --template '{{.status.id}}' "$APP_REF" 2>/dev/null || true)
[ "$GOT" = "$(image_id app)" ] || fail "the CRI reports '${GOT:-no such image}' for $APP_REF, expected $(image_id app)"
echo "  -> OK ($GOT)"

echo "[oracle] check 3: the unused images must be gone: the one no container ever used (C) and the one only a stopped container used (B). Gone means"
echo "[oracle]          the CRI no longer knows them, not even as a nameless '<none>' image, and k8s.io has neither their names nor their ids..."
for pair in "$UNUSED_REF:unused" "$JOB_REF:job"; do
    REF=${pair%:*}; ID=$(image_id "${pair##*:}")
    $CTR_T -n k8s.io images ls -q 2>/dev/null | grep -qxF "$REF" && fail "$REF is still listed in namespace k8s.io"
    if "${CRI[@]}" inspecti "$ID" >/dev/null 2>&1 || "${CRI[@]}" inspecti "$REF" >/dev/null 2>&1; then
        fail "the CRI still knows the image of $REF ($ID), e.g. as '<none>' in 'crictl images': it was not removed (only its name, or it is still used by a stopped container)"
    fi
    $CTR_T -n k8s.io images ls -q 2>/dev/null | grep -qxF "$ID" && fail "the record $ID of $REF is still in namespace k8s.io"
done
echo "  -> OK"

echo "[oracle] check 4: the disk space was given back, and what is still needed stayed: the shared layer, and every blob of A and of the sandbox image,"
echo "[oracle]          are still in the content store; the blobs of B and C are gone (containerd's garbage collection ran: polled for 40 s), and the content"
echo "[oracle]          store and the snapshots each shrank by at least 11 MiB, the 12 MiB the two removed images held in each..."
while read -r d; do
    sudo test -f "$BLOBS_DIR/${d#sha256:}" || fail "the blob $d, which an image in use (or the sandbox image) needs, is gone from the content store$([ "$d" = "$(st shared.digest)" ] && echo ' (it is the layer that A shares with the removed images)')"
done < "$STATE_DIR/blobs.keep"
read -r CB SB < "$STATE_DIR/bytes.base"
OK=""
for _ in $(seq 1 40); do
    LEFT=0; while read -r d; do sudo test -e "$BLOBS_DIR/${d#sha256:}" && LEFT=$((LEFT+1)); done < "$STATE_DIR/blobs.go"
    CN=$(bytes "$BLOBS_DIR"); SN=$(bytes "$SNAP_DIR")
    if [ "$LEFT" = 0 ] && [ $((CB - CN)) -ge "$RECLAIM_MIN" ] && [ $((SB - SN)) -ge "$RECLAIM_MIN" ]; then OK=1; break; fi
    sleep 1
done
if [ -z "$OK" ]; then
    MSG="blobs of the removed images still in the content store: $LEFT of $(wc -l < "$STATE_DIR/blobs.go")"
    MSG="$MSG; content store $CB -> $CN bytes (gave back $((CB - CN))), snapshots $SB -> $SN bytes (gave back $((SB - SN))), at least $RECLAIM_MIN each were to be"
    [ $((SB - SN)) -ge "$RECLAIM_MIN" ] || MSG="$MSG; the snapshots of the removed images are still held by something (a stopped container that uses them?)"
    fail "the space was not given back: $MSG"
fi
echo "  -> OK (content store $CB -> $CN bytes, snapshots $SB -> $SN bytes)"

echo "[oracle] check 5: the stopped containers must be gone (the two setup left, and no other exited container of this case)..."
for pair in "$CASE_ID-job:$JOB_ID" "$CASE_ID-old:$OLD_ID"; do
    NAME=${pair%%:*}; CID=${pair##*:}
    STATE=$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$CID" 2>/dev/null || true)
    [ -z "$STATE" ] || fail "the stopped container $NAME ($CID) still exists (state $STATE)"
done
[ -z "$("${CRI[@]}" ps -a -q --state exited 2>/dev/null)" ] || fail "exited container(s) are still there: $("${CRI[@]}" ps -a -q --state exited | tr '\n' ' ')"
echo "  -> OK"

echo "[oracle] check 6: image A still works: the oracle starts a NEW container from it through the CRI (the sandbox image is imported again if it was"
echo "[oracle]          removed), the container prints the marker it was given, and the files of the shared layer and of its own layer in its root"
echo "[oracle]          are byte for byte the ones that were put there..."
MARK=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
"${CRI[@]}" inspecti "$PAUSE_REF" >/dev/null 2>&1 || $CTR_T -n k8s.io images import "$STATE_DIR/pause-oracle.tar" >/dev/null 2>&1 || fail "the oracle could not import the sandbox image into the node's containerd"
python3 - "$WORK_DIR" "$CASE_ID" "$APP_REF" "$MARK" <<'PYEOF'
import json
import sys

work, case, ref, mark = sys.argv[1:5]
ns = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}
with open(work + "/oracle-pod.json", "w") as f:
    json.dump({"metadata": {"name": case + "-oracle-pod", "namespace": "default", "attempt": 1, "uid": case + "-oracle-uid"},
               "log_directory": work + "/logs", **ns}, f)
with open(work + "/oracle-probe.json", "w") as f:
    json.dump({"metadata": {"name": "oracle-probe"}, "image": {"image": ref}, "args": ["mark", mark], "log_path": "oracle-probe.log", **ns}, f)
PYEOF
POD=$("${CRI[@]}" runp "$WORK_DIR/oracle-pod.json" 2>"$STATE_DIR/runp_err.txt") || { head -3 "$STATE_DIR/runp_err.txt"; fail "the node cannot start a new pod sandbox"; }
CID=$("${CRI[@]}" create "$POD" "$WORK_DIR/oracle-probe.json" "$WORK_DIR/oracle-pod.json" 2>"$STATE_DIR/create_err.txt") \
    || { head -3 "$STATE_DIR/create_err.txt"; fail "the node cannot create a container from image A any more"; }
"${CRI[@]}" start "$CID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { head -3 "$STATE_DIR/start_err.txt"; fail "the new container cannot be started"; }
LINE=""
for _ in $(seq 1 30); do
    LINE=$("${CRI[@]}" logs "$CID" 2>/dev/null | grep -m1 "bench64460740 app marker=" || true)
    [ -n "$LINE" ] && break
    sleep 0.5
done
[ "$LINE" = "bench64460740 app marker=$MARK" ] || fail "the new container printed '$LINE', not the marker it was given"
NEWPID=$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$CID" 2>/dev/null)
[ "$(sudo sha256sum "/proc/$NEWPID/root/shared.bin" 2>/dev/null | awk '{print $1}')" = "$(sed -n 1p "$STATE_DIR/payload.sha")" ] || fail "the file of the shared layer (/shared.bin) in the new container is not the original: the shared layer was damaged"
[ "$(sudo sha256sum "/proc/$NEWPID/root/data/payload.bin" 2>/dev/null | awk '{print $1}')" = "$(sed -n 2p "$STATE_DIR/payload.sha")" ] || fail "the file of A's own layer (/data/payload.bin) in the new container is not the original"
alive_same t || fail "the node's containerd was replaced meanwhile"
echo "  -> OK ($LINE)"

echo "[oracle] ALL CHECKS PASSED"
