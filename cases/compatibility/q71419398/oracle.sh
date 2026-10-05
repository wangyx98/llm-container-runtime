#!/bin/bash
set -e

CASE_ID="bench71419398"
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
shim_pids() {   # live (not zombie) runc shims of one container id
    ps -eo pid=,stat=,comm=,args= | awk -v id="$1" '$2 !~ /^Z/ && $3 ~ /^containerd-shim/ && index($0, "-id " id " ") {print $1}'
}
TPID=$(awk -v t="$TARGET" '$2==t{print $3}' "$STATE_DIR/containers.truth")
CPID=$(awk -v t="$CONTROL" '$2==t{print $3}' "$STATE_DIR/containers.truth")
CTRL_TRUTH=$(awk -v t="$CONTROL" '$2==t' "$STATE_DIR/containers.truth")
read -r DPID DSTART < "$STATE_DIR/containerd.id"

echo "[oracle] check 1: the containerd must be the very process of the setup (same PID, same start"
echo "[oracle]          time): a restarted daemon proves nothing..."
if ! alive "$DPID" || [ "$(sudo awk '{print $22}' "/proc/$DPID/stat" 2>/dev/null)" != "$DSTART" ] || ! $CTR version >/dev/null 2>&1; then
    echo "  -> FAIL: the containerd of this task was restarted, stopped or replaced"
    exit 1
fi
echo "  -> OK (PID $DPID)"

echo "[oracle] check 2: containerd must know nothing of $TARGET any more: no task, no container"
echo "[oracle]          (neither in the lists nor by name)..."
ST=$(status_of "$TARGET")
if [ -n "$ST" ]; then
    echo "  -> FAIL: there is still a task of $TARGET, in state $ST"
    exit 1
fi
if $CTR -n "$NS" containers ls -q 2>/dev/null | grep -qx "$TARGET" || $CTR -n "$NS" containers info "$TARGET" >/dev/null 2>&1; then
    echo "  -> FAIL: the container $TARGET still exists in containerd"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: what the task held must be reclaimed: its shim and init process gone and every"
echo "[oracle]          directory recorded by setup (bundle, runc state, cgroups) removed..."
if [ -n "$(shim_pids "$TARGET")" ]; then
    echo "  -> FAIL: the shim process of $TARGET is still running"
    exit 1
fi
if alive "$TPID"; then
    echo "  -> FAIL: the init process $TPID of $TARGET is still there"
    exit 1
fi
while read -r pth; do
    if sudo test -e "$pth"; then
        echo "  -> FAIL: $pth is still there"
        exit 1
    fi
done < "$STATE_DIR/target.paths"
echo "  -> OK"

echo "[oracle] check 4: the healthy container $CONTROL must be untouched: same task and process,"
echo "[oracle]          its shim running, still listed, and its count growing in the window below..."
CTRL_LIVE=$($CTR -n "$NS" tasks ls 2>/dev/null | awk -v t="$CONTROL" '$1==t{print "'"$NS"'", $1, $2}')
if [ "$CTRL_LIVE" != "$CTRL_TRUTH" ] || [ "$(status_of "$CONTROL")" != "RUNNING" ] || ! alive "$CPID"; then
    echo "  -> FAIL: the task of $CONTROL is gone, changed or not running"
    exit 1
fi
if ! $CTR -n "$NS" containers ls -q 2>/dev/null | grep -qx "$CONTROL"; then
    echo "  -> FAIL: the container $CONTROL was deleted"
    exit 1
fi
if [ -z "$(shim_pids "$CONTROL")" ]; then
    echo "  -> FAIL: the shim of $CONTROL is gone"
    exit 1
fi
C1=$(count control)
sleep 1.5
C2=$(count control)
if [ "$C2" -le "$C1" ]; then
    echo "  -> FAIL: the count of $CONTROL does not grow ($C1 -> $C2)"
    exit 1
fi
echo "  -> OK ($CONTROL count $C1 -> $C2)"
echo "[oracle] all checks passed."
