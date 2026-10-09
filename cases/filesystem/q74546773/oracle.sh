#!/bin/bash
set -e

CASE_ID="bench74546773"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
VOL_DIR="$WORK_DIR/volume-path/mount"
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"
DUMP_PATH="/var/dump/app.hprof"

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
OUT_DIR="$WORK_DIR/out"
OUT2_DIR="$WORK_DIR/out2"
TOOL="$WORK_DIR/extract.sh"
sha() { sudo sha256sum "$1" | awk '{print $1}'; }
size() { sudo stat -c %s "$1"; }
devino() { sudo stat -c '%d:%i' "$1"; }

# the same container, process and heartbeat: not restarted, not recreated, still counting (and a counter that went on from setup's)
identity_ok() {
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || { echo "the workload container is not running (stopped, removed or recreated)"; return 1; }
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null)" = "$PID" ] || { echo "the workload runs under another host pid"; return 1; }
    [ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" 2>/dev/null | awk '{print $20}')" = "$(st starttime)" ] || { echo "the workload process was restarted (its start time changed)"; return 1; }
    local a b
    a=$(field beat "$(lastlog)"); sleep 2; b=$(field beat "$(lastlog)")
    [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] && [ "$a" -gt "$(st beat0)" ] || { echo "the heartbeat does not go on counting ($a -> $b, setup saw $(st beat0))"; return 1; }
    [ "$(field pid "$(lastlog)")" = "1" ] || { echo "the workload is not pid 1 any more"; return 1; }
}
# the original file, untouched: same inode and modification time, same size, same sha256 (read from inside the container's root)
source_ok() {
    local SRC="/proc/$PID/root$DUMP_PATH"
    [ "$(sudo stat -c '%i %Y.%y' "$SRC" 2>/dev/null)" = "$(st src.stat)" ] || { echo "the original dump was replaced or modified (inode or modification time changed)"; return 1; }
    [ "$(size "$SRC")" = "$(st dump.size)" ] || { echo "the original dump has another size"; return 1; }
    [ "$(sha "$SRC")" = "$(st dump.sha256)" ] || { echo "the original dump's content changed"; return 1; }
}
# a complete, independent copy: regular file (no symlink), other inode than the original, expected size and sha256
copy_ok() {   # $1 = file, $2 = expected size, $3 = expected sha256, $4 = path of the original in the container's root
    [ -f "$1" ] && [ ! -L "$1" ] || { echo "$1 is not a regular file (missing, or a symlink)"; return 1; }
    [ "$(size "$1")" = "$2" ] || { echo "$1 has $(size "$1") bytes, expected $2"; return 1; }
    [ "$(sha "$1")" = "$3" ] || { echo "$1 has not the expected sha256"; return 1; }
    [ "$(devino "$1")" != "$(devino "$4")" ] || { echo "$1 is the original file itself (a hard link or a bind mount), not a copy"; return 1; }
}

echo "[oracle] check 0: the node's containerd is still the one of setup, its start script is unchanged, and its CRI answers..."
alive_same containerd || fail "containerd is not the process of setup (it was restarted or replaced)"
[ "$(sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}')" = "$(st containerdctl.sha)" ] || fail "$CTL_DIR/containerdctl was changed"
for _ in $(seq 1 30); do "${CRI[@]}" version >/dev/null 2>&1 && break; sleep 1; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
for f in container_app pid starttime dump.sha256 dump.size src.stat beat0; do
    [ -n "$(st $f)" ] || fail "setup's recorded $f is missing"
done
APP_ID=$(st container_app); PID=$(st pid)
echo "  -> OK"

echo "[oracle] check 1: the workload is the same container and process, still running, and its heartbeat goes on..."
MSG=$(identity_ok) || fail "$MSG"
echo "  -> OK (host pid $PID, $(lastlog))"

echo "[oracle] check 2: the original dump in the container is untouched (inode, modification time, size, sha256 as setup recorded)..."
MSG=$(source_ok) || fail "$MSG"
echo "  -> OK"

echo "[oracle] check 3: the dump was copied out in full: $OUT_DIR/app.hprof is a regular file of the expected size with the sha256 the"
echo "[oracle]          oracle computed on its own, and not the original file itself..."
SRC="/proc/$PID/root$DUMP_PATH"
MSG=$(copy_ok "$OUT_DIR/app.hprof" "$(st dump.size)" "$(st dump.sha256)" "$SRC") || fail "$MSG"
echo "  -> OK ($(size "$OUT_DIR/app.hprof") bytes, $(cut -c1-16 <<<"$(st dump.sha256)")...)"

echo "[oracle] check 4: the extraction is a tool, not a one-off: the oracle makes the workload write a NEW file (a marker of random"
echo "[oracle]          content and size, requested through the pod's volume), and runs $TOOL for it..."
[ -f "$TOOL" ] || fail "$TOOL does not exist (the solution must leave the extraction as that script)"
R=$(python3 -c 'import secrets; print("%016x" % secrets.randbits(64))')
python3 - "$R" <<'PY'
import sys
base = "/tmp/bench74546773/volume-path/mount/"
open(base + "trigger.tmp", "w").write(sys.argv[1] + "\n")
import os
os.rename(base + "trigger.tmp", base + "trigger")
PY
GOT=""
for _ in $(seq 1 30); do
    [ "$(field marker "$(lastlog)")" = "$R" ] && { GOT=1; break; }
    sleep 0.5
done
[ -n "$GOT" ] || fail "the workload did not write the marker file (the oracle's own request failed; log: $(lastlog))"
MSIZE=$(python3 -c 'import sys; print(1048576 + (int(sys.argv[1], 16) & 0xFFF))' "$R")
MSHA=$(python3 "$STATE_DIR/stream.py" "0x$R" "$MSIZE")
sudo mkdir -p "$OUT2_DIR"
if ! sudo timeout -k 5 120 bash "$TOOL" "$APP_NAME" "/var/dump/marker-$R" "$OUT2_DIR/marker-$R" > "$WORK_DIR/tool_marker.log" 2>&1 </dev/null; then
    tail -3 "$WORK_DIR/tool_marker.log" | cut -c1-200
    fail "$TOOL exited with an error for the marker file"
fi
MSG=$(copy_ok "$OUT2_DIR/marker-$R" "$MSIZE" "$MSHA" "/proc/$PID/root/var/dump/marker-$R") || { tail -3 "$WORK_DIR/tool_marker.log" | cut -c1-200; fail "marker file: $MSG"; }
echo "  -> OK (marker-$R: $MSIZE bytes)"

echo "[oracle] check 5: the same tool extracts the big dump again, to another place, with the same result..."
if ! sudo timeout -k 5 120 bash "$TOOL" "$APP_NAME" "$DUMP_PATH" "$OUT2_DIR/app.hprof" > "$WORK_DIR/tool_dump.log" 2>&1 </dev/null; then
    tail -3 "$WORK_DIR/tool_dump.log" | cut -c1-200
    fail "$TOOL exited with an error for the dump"
fi
MSG=$(copy_ok "$OUT2_DIR/app.hprof" "$(st dump.size)" "$(st dump.sha256)" "$SRC") || fail "second extraction: $MSG"
echo "  -> OK"

echo "[oracle] check 6: after all that the workload is still the same running process with a counting heartbeat, and the original dump"
echo "[oracle]          is still untouched..."
MSG=$(identity_ok) || fail "$MSG"
MSG=$(source_ok) || fail "$MSG"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
