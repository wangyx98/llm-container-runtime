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
count() { echo $((10#$(sudo cat "$SHARED_DIR/$1/count" 2>/dev/null || echo 0))); }
status_of() { $CTR -n "$NS" tasks ls 2>/dev/null | awk -v t="$1" '$1==t{print $3}'; }
alive() { [ -r "/proc/$1/status" ] && ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$1/status"; }
TPID=$(awk -v t="$TARGET" '$2==t{print $3}' "$STATE_DIR/containers.truth")
CPID=$(awk -v t="$CONTROL" '$2==t{print $3}' "$STATE_DIR/containers.truth")
CTRL_TRUTH=$(awk -v t="$CONTROL" '$2==t' "$STATE_DIR/containers.truth")

echo "[oracle] check 1: the private containerd must be the process of the setup and the task of"
echo "[oracle]          $CONTROL must be the one it was (same task, same main process)..."
if ! sudo kill -0 "$(cat "$RUN_BASE/containerd.pid" 2>/dev/null)" 2>/dev/null || ! $CTR version >/dev/null 2>&1; then
    echo "  -> FAIL: the containerd of this task is not running (it was stopped or replaced)"
    exit 1
fi
CTRL_LIVE=$($CTR -n "$NS" tasks ls 2>/dev/null | awk -v t="$CONTROL" '$1==t{print "'"$NS"'", $1, $2}')
if [ "$CTRL_LIVE" != "$CTRL_TRUTH" ]; then
    echo "  -> FAIL: the task of $CONTROL is gone or was replaced"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: $TARGET must be stopped: no task of it left in containerd (not running,"
echo "[oracle]          not even a stopped one), and its main process (PID $TPID) gone..."
ST=$(status_of "$TARGET")
if [ "$ST" = "RUNNING" ] || [ "$ST" = "PAUSED" ] || [ "$ST" = "PAUSING" ]; then
    echo "  -> FAIL: the task of $TARGET is still $ST when the script has finished"
    exit 1
fi
if [ -n "$ST" ]; then
    echo "  -> FAIL: the task of $TARGET is $ST: it has ended but was not deleted"
    exit 1
fi
if alive "$TPID"; then
    echo "  -> FAIL: the main process $TPID of $TARGET still exists"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: the container itself must be kept, as the task asks (stop, not remove):"
echo "[oracle]          $TARGET and $CONTROL must both still be listed..."
CL=$($CTR -n "$NS" containers ls -q 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
if [ "$CL" != "$CONTROL $TARGET " ]; then
    echo "  -> FAIL: the containers of the namespace are now: $CL"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 4: $TARGET must have been asked to end with SIGTERM and given the time to"
echo "[oracle]          clean up: the cleanup marker with its final count must exist..."
MARK=$(sudo cat "$SHARED_DIR/target/term_marker" 2>/dev/null || true)
if [ -z "$MARK" ]; then
    echo "  -> FAIL: no cleanup marker: the program was killed before it could handle SIGTERM"
    exit 1
fi
FINAL=$(count target)
if ! echo "$MARK" | grep -qx "terminated-by-SIGTERM count=$FINAL"; then
    echo "  -> FAIL: the cleanup marker ('$MARK') does not match the final count $FINAL"
    exit 1
fi
echo "  -> OK ($MARK)"

echo "[oracle] check 5: the count of $TARGET must have stopped for good (window of 1.5 seconds),"
echo "[oracle]          while the count of $CONTROL keeps growing and its task is RUNNING..."
T1=$(count target); C1=$(count control)
sleep 1.5
T2=$(count target); C2=$(count control)
if [ "$T2" -ne "$T1" ]; then
    echo "  -> FAIL: the count of $TARGET still changes ($T1 -> $T2)"
    exit 1
fi
if [ "$(status_of "$CONTROL")" != "RUNNING" ] || ! alive "$CPID"; then
    echo "  -> FAIL: the task of $CONTROL is $(status_of "$CONTROL"), it was affected"
    exit 1
fi
if [ "$C2" -le "$C1" ]; then
    echo "  -> FAIL: the count of $CONTROL does not grow ($C1 -> $C2), it was affected"
    exit 1
fi
if [ -e "$SHARED_DIR/control/term_marker" ]; then
    echo "  -> FAIL: $CONTROL was sent SIGTERM as well"
    exit 1
fi
echo "  -> OK ($TARGET stays at $T1, $CONTROL $C1 -> $C2)"
echo "[oracle] all checks passed."
