#!/bin/bash
set -e

CASE_ID="bench71557667"
RUN_BASE="/run/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"
NS="openfaas-fn"
FN="$CASE_ID-fn"
FN_OTHER="$CASE_ID-other-fn"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ANSWER="$WORK_DIR/answer.json"

CTR="sudo ctr -a $SOCK"
read_marker() { $CTR -n "$NS" tasks exec --exec-id "$CASE_ID-pre-$$-$RANDOM" "$1" /bin/cat /run/marker </dev/null 2>/dev/null; }

echo "[precondition] checking the private containerd answers on $SOCK and the work files exist..."
[ -S "$SOCK" ] || { echo "  -> FAIL: $SOCK is not a socket"; exit 1; }
$CTR version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
[ -s "$RUN_BASE/containerd.pid" ] || { echo "  -> FAIL: no containerd pid recorded"; exit 1; }
sudo kill -0 "$(cat "$RUN_BASE/containerd.pid")" 2>/dev/null || { echo "  -> FAIL: the recorded containerd is not running"; exit 1; }
[ -s "$STATE_DIR/containers.truth" ] || { echo "  -> FAIL: setup did not record the functions"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the answer file does not exist yet..."
if [ -e "$ANSWER" ]; then
    echo "  -> FAIL: $ANSWER already exists"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the two functions run as tasks in $NS and are the ones setup recorded..."
LIVE=$($CTR -n "$NS" tasks ls 2>/dev/null | awk 'NR>1{print "'"$NS"'", $1, $2}' | LC_ALL=C sort)
if [ "$LIVE" != "$(cat "$STATE_DIR/containers.truth")" ]; then
    echo "  -> FAIL: the tasks changed since setup"
    exit 1
fi
N=$($CTR -n "$NS" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
[ "$N" -eq 2 ] || { echo "  -> FAIL: expected 2 running tasks, found $N"; exit 1; }
echo "  -> OK ($FN and $FN_OTHER running)"

echo "[precondition] checking each function has its own marker inside its container, the markers"
echo "[precondition] differ, and the containers have their own PID namespaces (not the host's)..."
M1=$(read_marker "$FN") || true
M2=$(read_marker "$FN_OTHER") || true
case "$M1" in bench71557667-marker-*) ;; *) echo "  -> FAIL: no marker in $FN"; exit 1 ;; esac
case "$M2" in bench71557667-marker-*) ;; *) echo "  -> FAIL: no marker in $FN_OTHER"; exit 1 ;; esac
[ "$M1" != "$M2" ] || { echo "  -> FAIL: both functions have the same marker"; exit 1; }
P1=$(awk -v f="$FN" '$2==f{print $3}' "$STATE_DIR/containers.truth")
P2=$(awk -v f="$FN_OTHER" '$2==f{print $3}' "$STATE_DIR/containers.truth")
NS1=$(sudo readlink "/proc/$P1/ns/pid"); NS2=$(sudo readlink "/proc/$P2/ns/pid"); HOST_NS=$(readlink /proc/self/ns/pid)
if [ -z "$NS1" ] || [ "$NS1" = "$NS2" ] || [ "$NS1" = "$HOST_NS" ] || [ "$NS2" = "$HOST_NS" ]; then
    echo "  -> FAIL: the PID namespaces are not distinct ($NS1, $NS2, host $HOST_NS)"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the symptom: the functions are not visible where an engineer looks"
echo "[precondition] first: ctr's default namespace holds no container, and an exec there fails..."
if [ -n "$($CTR containers ls -q 2>/dev/null)" ]; then
    echo "  -> FAIL: the default namespace of the private containerd holds containers"
    exit 1
fi
if OUT=$($CTR tasks exec --exec-id "$CASE_ID-pre-default" "$FN" /bin/cat /run/marker </dev/null 2>&1); then
    echo "  -> FAIL: an exec in the default namespace works"
    exit 1
fi
echo "  -> OK ($(echo "$OUT" | tail -1 | cut -c1-100))"

echo "[precondition] all conditions met."
