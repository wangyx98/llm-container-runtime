#!/bin/bash
set -e

CASE_ID="bench67990326"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
APP_NAME="$CASE_ID-app"
TOOL="$WORK_DIR/cp.sh"
OUT_FILE="$WORK_DIR/out/report.bin"

CTR="sudo ctr -a $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
lastlog() { "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | tail -1; }      # the newest line the workload printed
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$2"; }                         # field of such a line
sha() { sudo sha256sum "$1" | awk '{print $1}'; }
size() { sudo stat -c %s "$1"; }
devino() { sudo stat -c '%d:%i' "$1"; }
APP_ID=$(st container_app); PID=$(st pid)
REPORT_SIZE=$(st report.size)

echo "[precondition] checking the node's containerd (the process of setup), its CRI, and the container..."
for f in containerd.id container_app pid starttime beat0 report.size report_new.sha256 report_old.sha256 src.stat snapkey snapshots.list upperdir lowerdirs mounts.count containers.list images.list; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same containerd || fail "the recorded containerd is not running"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the container is not running"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null)" = "$PID" ] || fail "the container has another host pid"
[ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}')" = "$(st starttime)" ] || fail "the container process has another start time"
L1=$(lastlog); sleep 2; L2=$(lastlog)
[ "$(field beat "$L2")" -gt "$(field beat "$L1")" ] || fail "the heartbeat does not advance ($L1 / $L2)"
[ "$(field pid "$L2")" = "1" ] || fail "the service is not pid 1 in its own pid namespace"
echo "  -> OK ($L2)"

echo "[precondition] checking the report: /data/report.bin in the container's root has the NEW content (recorded size and sha256), it lives in the"
echo "[precondition] container's ACTIVE snapshot (its writable layer), and the image's committed layer still holds an OLD file of the same name"
echo "[precondition] and size (so size does not tell the two apart, and the image's layer or a view of it is the wrong thing to copy from)..."
SRC="/proc/$PID/root/data/report.bin"
[ "$(size "$SRC")" = "$REPORT_SIZE" ] || fail "the report has not the recorded size"
[ "$(sha "$SRC")" = "$(st report_new.sha256)" ] || fail "the report's sha256 is not the recorded one"
[ "$(sudo stat -c '%i %Y %s' "$SRC")" = "$(st src.stat)" ] || fail "the report was changed since setup"
UPPER=$(st upperdir)
[ "$(sha "$UPPER/data/report.bin")" = "$(st report_new.sha256)" ] || fail "the writable layer of the container does not hold the new report"
LOWER=$(st lowerdirs | head -1)
[ "$(size "$LOWER/data/report.bin")" = "$REPORT_SIZE" ] || fail "the image's copy has another size"
[ "$(sha "$LOWER/data/report.bin")" = "$(st report_old.sha256)" ] || fail "the image's copy is not the old one"
[ "$(st report_old.sha256)" != "$(st report_new.sha256)" ] || fail "old and new report are the same"
SNAPKEY=$(st snapkey)
[ "$($CTR -n k8s.io containers info "$APP_ID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["SnapshotKey"])')" = "$SNAPKEY" ] || fail "the container's snapshot key is not the recorded one"
grep -q "^$SNAPKEY .* Active$" < <($CTR -n k8s.io snapshots ls 2>/dev/null | awk 'NR>1 {print $1, $2, $3}') || fail "the container's snapshot is not active"
echo "  -> OK (new $(st report_new.sha256 | cut -c1-16)... in the active snapshot $SNAPKEY; old $(st report_old.sha256 | cut -c1-16)... in the image layer)"

echo "[precondition] checking that nothing can read the file from inside (no cat, tar, cp or sh in the image) and that there is no copy on the node,"
echo "[precondition] nor the tool of the answer yet..."
for t in cat tar cp sh; do
    if "${CRI[@]}" exec "$APP_ID" "/bin/$t" --version >/dev/null 2>&1; then fail "the container has /bin/$t"; fi
done
OUT=$("${CRI[@]}" exec "$APP_ID" cat /data/report.bin 2>&1 >/dev/null || true)
echo "     crictl exec cat inside the container: $(head -1 <<<"$OUT" | cut -c1-110)"
[ -n "$OUT" ] || fail "'crictl exec <app> cat' works: the file could be read from inside"
if sudo find "$WORK_DIR" -xdev -type f -size "${REPORT_SIZE}c" -not -path '*/.bench/*' 2>/dev/null | grep -q .; then fail "a file of the size of the report already sits under $WORK_DIR"; fi
[ ! -e "$TOOL" ] || fail "$TOOL exists already"
echo "  -> OK"

echo "[precondition] the thread's answer as a CONTROL: 'ctr snapshots mounts DIR KEY' only PRINTS a mount command and mounts nothing: DIR stays"
echo "[precondition] empty (the comment under the answer: 'I could not find any files')..."
PROBE=$(mktemp -d "$WORK_DIR/probe.XXXXXX")
OUT=$($CTR -n k8s.io snapshots mounts "$PROBE" "$SNAPKEY" 2>/dev/null) && RC=0 || RC=$?
LEFT=$(ls -A "$PROBE" | wc -l)
rmdir "$PROBE" 2>/dev/null || true
echo "     exit code $RC; it printed: $(cut -c1-60 <<<"$OUT")...; files in the directory: $LEFT"
[ "$RC" = 0 ] && grep -q '^mount -t overlay' <<<"$OUT" || fail "ctr snapshots mounts did not print an overlay mount command"
[ "$LEFT" = 0 ] || fail "the control directory is not empty"
[ "$(grep -c "upperdir=$UPPER" /proc/self/mounts || true)" = "$(st mounts.count)" ] || fail "the control left a mount behind"
echo "  -> OK"

echo "[precondition] PASS - a $REPORT_SIZE byte report with a known sha256 sits in the writable layer (active snapshot) of the running container; the"
echo "[precondition]        image holds an old one of the same size; nothing in the container can read it out; ctr snapshots mounts alone gets nothing."
