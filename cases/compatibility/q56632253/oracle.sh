#!/bin/bash
set -e

CASE_ID="bench56632253"
RUN_BASE="/run/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"
NS="$CASE_ID"
TARGET="$CASE_ID-target"
CONTROL="$CASE_ID-control"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SHARED_DIR="$WORK_DIR/shared"

CTR="sudo ctr -a $SOCK"
count() { echo $((10#$(sudo cat "$SHARED_DIR/$1/count" 2>/dev/null || echo 0))); }
status_of() { $CTR -n "$NS" tasks ls 2>/dev/null | awk -v t="$1" '$1==t{print $3}'; }
alive() { [ -r "/proc/$1/status" ] && ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$1/status"; }
TPID=$(awk -v t="$TARGET" '$2==t{print $3}' "$STATE_DIR/containers.truth")
CPID=$(awk -v t="$CONTROL" '$2==t{print $3}' "$STATE_DIR/containers.truth")

echo "[oracle] check 1: the private containerd must be the same process as before and still hold"
echo "[oracle]          both tasks, with the same main processes (nothing restarted or deleted)..."
if ! sudo kill -0 "$(cat "$RUN_BASE/containerd.pid" 2>/dev/null)" 2>/dev/null || ! $CTR version >/dev/null 2>&1; then
    echo "  -> FAIL: the containerd of this task is not running (it was stopped or replaced)"
    exit 1
fi
LIVE=$($CTR -n "$NS" tasks ls 2>/dev/null | awk 'NR>1{print "'"$NS"'", $1, $2}' | LC_ALL=C sort)
if [ "$LIVE" != "$(cat "$STATE_DIR/containers.truth")" ]; then
    echo "  -> FAIL: the tasks were killed, restarted, deleted or changed"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: the task of $TARGET must be PAUSED according to containerd, and its main"
echo "[oracle]          process (PID $TPID) must still be alive..."
ST=$(status_of "$TARGET")
if [ "$ST" != "PAUSED" ]; then
    echo "  -> FAIL: the task of $TARGET is $ST, not PAUSED"
    exit 1
fi
if ! alive "$TPID"; then
    echo "  -> FAIL: the main process $TPID of $TARGET is gone"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: the other container must not be affected: its task RUNNING and its count"
echo "[oracle]          growing in the observation window below..."
CT1=$(count control)
T1=$(count target)
sleep 2.5
T2=$(count target); CT2=$(count control)
if [ "$(status_of "$CONTROL")" != "RUNNING" ] || ! alive "$CPID"; then
    echo "  -> FAIL: the task of $CONTROL is $(status_of "$CONTROL"), it was affected"
    exit 1
fi
if [ "$CT2" -le "$CT1" ]; then
    echo "  -> FAIL: the count of $CONTROL does not grow ($CT1 -> $CT2), it was affected"
    exit 1
fi
echo "  -> OK ($CONTROL count $CT1 -> $CT2)"

echo "[oracle] check 4: the count of $TARGET must not grow in a window of 2.5 seconds (the program"
echo "[oracle]          writes it with plain write() calls, so nothing is left in a buffer)..."
if [ "$T2" -ne "$T1" ]; then
    echo "  -> FAIL: the count of $TARGET keeps growing ($T1 -> $T2): its process is not frozen"
    exit 1
fi
echo "  -> OK (stays at $T1)"

echo "[oracle] check 5: when resumed (the oracle resumes it itself), the same process must run on:"
echo "[oracle]          status RUNNING again and the count counting on from where it stood..."
$CTR -n "$NS" tasks resume "$TARGET" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    [ "$(status_of "$TARGET")" = "RUNNING" ] && break
    sleep 0.25
done
if [ "$(status_of "$TARGET")" != "RUNNING" ]; then
    echo "  -> FAIL: the task of $TARGET does not return to RUNNING when resumed"
    exit 1
fi
sleep 1.5
T3=$(count target)
if ! alive "$TPID" || [ "$T3" -le "$T2" ] || [ "$T3" -gt $((T2 + 100)) ]; then
    echo "  -> FAIL: after the resume the count went $T2 -> $T3: the process does not continue where it stopped"
    exit 1
fi
echo "  -> OK (count $T2 -> $T3, same process $TPID)"
echo "[oracle] all checks passed."
