#!/bin/bash
set -e

CASE_ID="bench67171982"
RUN_BASE="/run/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"
NS="$CASE_ID"
TARGET="$CASE_ID-target"
CONTROL="$CASE_ID-control"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SHARED_DIR="$WORK_DIR/shared"

CTR="sudo ctr -a $SOCK"

echo "[precondition] checking the private containerd answers on $SOCK and the work files exist..."
[ -S "$SOCK" ] || { echo "  -> FAIL: $SOCK is not a socket"; exit 1; }
$CTR version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
[ -s "$RUN_BASE/containerd.pid" ] || { echo "  -> FAIL: no containerd pid recorded"; exit 1; }
sudo kill -0 "$(cat "$RUN_BASE/containerd.pid")" 2>/dev/null || { echo "  -> FAIL: the recorded containerd is not running"; exit 1; }
[ -s "$STATE_DIR/containers.truth" ] || { echo "  -> FAIL: setup did not record the containers"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the two containers run as tasks in $NS and are the ones setup recorded..."
LIVE=$($CTR -n "$NS" tasks ls 2>/dev/null | awk 'NR>1{print "'"$NS"'", $1, $2}' | LC_ALL=C sort)
if [ "$LIVE" != "$(cat "$STATE_DIR/containers.truth")" ]; then
    echo "  -> FAIL: the tasks changed since setup"
    exit 1
fi
N=$($CTR -n "$NS" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
[ "$N" -eq 2 ] || { echo "  -> FAIL: expected 2 running tasks, found $N"; exit 1; }
echo "  -> OK ($TARGET and $CONTROL running)"

echo "[precondition] checking both containers count: both counts must grow within a second and a half..."
T1=$((10#$(cat "$SHARED_DIR/target/count"))); C1=$((10#$(cat "$SHARED_DIR/control/count")))
sleep 1.5
T2=$((10#$(cat "$SHARED_DIR/target/count"))); C2=$((10#$(cat "$SHARED_DIR/control/count")))
if [ "$T2" -le "$T1" ] || [ "$C2" -le "$C1" ]; then
    echo "  -> FAIL: a count does not grow (target $T1 -> $T2, control $C1 -> $C2)"
    exit 1
fi
echo "  -> OK (target $T1 -> $T2, control $C1 -> $C2)"

echo "[precondition] checking the symptom: neither 'ctr containers' nor 'ctr tasks' has a stop command..."
if $CTR containers --help 2>/dev/null | grep -qiw stop || $CTR tasks --help 2>/dev/null | grep -qiw stop; then
    echo "  -> FAIL: ctr has a stop command in this version"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking nothing has been stopped yet: no cleanup marker, containers listed..."
if [ -e "$SHARED_DIR/target/term_marker" ] || [ -e "$SHARED_DIR/control/term_marker" ]; then
    echo "  -> FAIL: a cleanup marker exists before anything was stopped"
    exit 1
fi
CL=$($CTR -n "$NS" containers ls -q 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
if [ "$CL" != "$CONTROL $TARGET " ]; then
    echo "  -> FAIL: unexpected containers: $CL"
    exit 1
fi
echo "  -> OK"

echo "[precondition] all conditions met."
