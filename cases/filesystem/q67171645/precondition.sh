#!/bin/bash
set -e

CASE_ID="bench67171645"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_ROOT="$LIB_BASE/containerd"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
O_SOCK="$RUN_BASE/other/containerd.sock"
O_CFG="$LIB_BASE/other-etc/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
BLOBS_DIR="$T_ROOT/io.containerd.content.v1.content/blobs/sha256"

CTR_T="sudo ctr -a $T_SOCK"
CTR_O="sudo ctr -a $O_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
snapshot() {   # $1 = socket: what the daemon holds, in every namespace (namespaces, images, containers, tasks, snapshots)
    local ns
    sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort | sed 's/^/ns /'
    for ns in $(sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort); do
        sudo ctr -a "$1" -n "$ns" images ls -q 2>/dev/null | sort | sed "s/^/image $ns /"
        sudo ctr -a "$1" -n "$ns" containers ls -q 2>/dev/null | sort | sed "s/^/container $ns /"
        sudo ctr -a "$1" -n "$ns" tasks ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort | sed "s/^/task $ns /"
        sudo ctr -a "$1" -n "$ns" snapshots ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort | sed "s/^/snapshot $ns /"
    done
}
APP_ID=$(st container_app); JOB_ID=$(st container_job); PID=$(st pid)

echo "[precondition] checking both containerd daemons (the processes of setup), the node's CRI, and that nothing was changed..."
for f in t.id o.id otherpid.id container_app container_job pod1_id pod2_id pid starttime beat0 o.snapshot t.metadb.inode config.sha blobs.list pause-oracle.tar; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same t || fail "the node's containerd is not running"
alive_same o || fail "the other containerd is not running"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer"
$CTR_O version >/dev/null 2>&1 || fail "the other containerd does not answer"
echo "  -> OK"

echo "[precondition] checking the node: two ready pod sandboxes, the workload RUNNING (host pid and start time as recorded, counting) and the"
echo "[precondition] one-shot job EXITED with code 0..."
[ "$("${CRI[@]}" pods -q | wc -l)" = 2 ] || fail "the node does not have exactly two pod sandboxes"
[ "$("${CRI[@]}" pods --state Ready -q | wc -l)" = 2 ] || fail "the two pod sandboxes are not both ready"
[ "$("${CRI[@]}" ps -a -q | wc -l)" = 2 ] || fail "the node does not have exactly two containers"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the workload is not running"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}} {{.status.exitCode}}' "$JOB_ID" 2>/dev/null)" = "CONTAINER_EXITED 0" ] || fail "the job has not finished with code 0"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID")" = "$PID" ] || fail "the workload has another host pid"
[ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}')" = "$(st starttime)" ] || fail "the workload has another start time"
L1=$("${CRI[@]}" logs --tail=1 "$APP_ID" | tail -1); sleep 2; L2=$("${CRI[@]}" logs --tail=1 "$APP_ID" | tail -1)
B1=$(sed -n 's/.* beat=\([0-9]*\) .*/\1/p' <<<"$L1"); B2=$(sed -n 's/.* beat=\([0-9]*\) .*/\1/p' <<<"$L2")
[ -n "$B1" ] && [ "$B2" -gt "$B1" ] || fail "the workload's heartbeat does not advance ($L1 / $L2)"
echo "  -> OK ($L2)"

echo "[precondition] checking the images of the node: four images (five names) in k8s.io, known to the CRI, and their blobs (12) on disk with"
echo "[precondition] real size (the three layers with payload hold 3 MiB each)..."
[ "$($CTR_T -n k8s.io images ls -q 2>/dev/null | grep -c '^bench67171645')" = 5 ] || fail "k8s.io does not hold the five image names"
[ "$("${CRI[@]}" images -q | wc -l)" = 4 ] || fail "the CRI does not list four images"
while read -r d; do
    sudo test -f "$BLOBS_DIR/${d#sha256:}" || fail "the blob $d is not in the content store"
done < "$STATE_DIR/blobs.list"
BYTES=$(sudo du -sb "$BLOBS_DIR" | awk '{print $1}')
[ "$BYTES" -gt 9000000 ] || fail "the content store holds only $BYTES bytes"
[ "$($CTR_T -n k8s.io snapshots ls 2>/dev/null | awk 'NR>1' | wc -l)" -ge 4 ] || fail "the node has too few snapshots"
echo "  -> OK ($BYTES bytes of blobs)"

echo "[precondition] checking the other containerd: its own image and a running container, as recorded; the node's data directory is intact..."
[ "$(snapshot "$O_SOCK")" = "$(st o.snapshot)" ] || fail "the other containerd does not hold what setup recorded"
alive_same otherpid || fail "the other containerd's container process is not the recorded one"
[ "$($CTR_O -n k8s.io tasks ls 2>/dev/null | awk 'NR>1 {print $3}')" = RUNNING ] || fail "the other containerd's container is not running"
[ "$(sudo stat -c %i "$T_ROOT/io.containerd.metadata.v1.bolt/meta.db")" = "$(st t.metadb.inode)" ] || fail "the node's metadata database is not the recorded one"
echo "  -> OK"

echo "[precondition] the thread's answer as a CONTROL, on the running workload only (nothing else is touched): 'ctr c rm' refuses to delete a"
echo "[precondition] container that has a running task, and the sandboxes of the pods are containers of k8s.io too..."
OUT=$($CTR_T -n k8s.io containers rm "$APP_ID" 2>&1 >/dev/null || true)
echo "     $(grep -v DEPRECATION <<<"$OUT" | tail -1 | cut -c1-110)"
grep -q "non stopped container" <<<"$OUT" || fail "'ctr c rm' of the running container did not refuse"
[ "$($CTR_T -n k8s.io containers ls -q 2>/dev/null | wc -l)" = 4 ] || fail "k8s.io should list four containers: the two sandboxes, the workload and the job"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the control disturbed the workload"
echo "  -> OK"

echo "[precondition] PASS - a node with two pods, a running workload, a finished job and four images that take space, next to another"
echo "[precondition]        containerd that must not be touched; the thread's command cannot clear it."
