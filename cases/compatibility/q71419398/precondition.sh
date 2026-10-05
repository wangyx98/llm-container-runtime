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
status_of() { $CTR -n "$NS" tasks ls 2>/dev/null | awk -v t="$1" '$1==t{print $3}'; }
shim_pids() {   # live (not zombie) runc shims of one container id
    ps -eo pid=,stat=,comm=,args= | awk -v id="$1" '$2 !~ /^Z/ && $3 ~ /^containerd-shim/ && index($0, "-id " id " ") {print $1}'
}

echo "[precondition] checking the private containerd answers on $SOCK and the work files exist..."
[ -S "$SOCK" ] || { echo "  -> FAIL: $SOCK is not a socket"; exit 1; }
$CTR version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
[ -s "$STATE_DIR/containerd.id" ] || { echo "  -> FAIL: setup did not record the containerd"; exit 1; }
[ -s "$STATE_DIR/containers.truth" ] || { echo "  -> FAIL: setup did not record the tasks"; exit 1; }
read -r DPID DSTART < "$STATE_DIR/containerd.id"
if grep -q '^State:[[:space:]]*[ZX]' "/proc/$DPID/status" 2>/dev/null || [ "$(sudo awk '{print $22}' "/proc/$DPID/stat" 2>/dev/null)" != "$DSTART" ]; then
    echo "  -> FAIL: the recorded containerd is not running"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the state: the task of $TARGET is CREATED, the one of $CONTROL RUNNING,"
echo "[precondition] and they are the tasks setup recorded..."
LIVE=$($CTR -n "$NS" tasks ls 2>/dev/null | awk 'NR>1{print "'"$NS"'", $1, $2}' | LC_ALL=C sort)
if [ "$LIVE" != "$(cat "$STATE_DIR/containers.truth")" ]; then
    echo "  -> FAIL: the tasks changed since setup"
    exit 1
fi
[ "$(status_of "$TARGET")" = "CREATED" ] || { echo "  -> FAIL: the task of $TARGET is $(status_of "$TARGET")"; exit 1; }
[ "$(status_of "$CONTROL")" = "RUNNING" ] || { echo "  -> FAIL: the task of $CONTROL is $(status_of "$CONTROL")"; exit 1; }
CL=$($CTR -n "$NS" containers ls -q 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
[ "$CL" = "$CONTROL $TARGET " ] || { echo "  -> FAIL: unexpected containers: $CL"; exit 1; }
echo "  -> OK"

echo "[precondition] checking what there is to reclaim for $TARGET: a shim, an init process and the"
echo "[precondition] directories setup found for it (bundle, runc state, cgroups)..."
TPID=$(awk -v t="$TARGET" '$2==t{print $3}' "$STATE_DIR/containers.truth")
[ -n "$(shim_pids "$TARGET")" ] || { echo "  -> FAIL: no shim process for $TARGET"; exit 1; }
[ -r "/proc/$TPID/status" ] || { echo "  -> FAIL: the init process $TPID of $TARGET does not exist"; exit 1; }
[ -s "$STATE_DIR/target.paths" ] || { echo "  -> FAIL: setup recorded no path of $TARGET"; exit 1; }
while read -r pth; do
    sudo test -e "$pth" || { echo "  -> FAIL: $pth does not exist"; exit 1; }
done < "$STATE_DIR/target.paths"
echo "  -> OK (init PID $TPID; $(wc -l < "$STATE_DIR/target.paths") paths: $(tr '\n' ' ' < "$STATE_DIR/target.paths"))"

echo "[precondition] checking the symptom: both the plain container delete and the plain task delete"
echo "[precondition] are refused, and nothing changes..."
if $CTR -n "$NS" containers delete "$TARGET" >/dev/null 2>&1; then
    echo "  -> FAIL: 'ctr containers delete' worked"
    exit 1
fi
if $CTR -n "$NS" tasks delete "$TARGET" >/dev/null 2>&1; then
    echo "  -> FAIL: 'ctr tasks delete' worked"
    exit 1
fi
if $CTR -n "$NS" containers delete "$TARGET" 2>&1 | grep -qi "must be stopped"; then :; else
    echo "  -> FAIL: the refusal does not say that the task must be stopped"
    exit 1
fi
[ "$(status_of "$TARGET")" = "CREATED" ] || { echo "  -> FAIL: the refused deletes changed the task"; exit 1; }
echo "  -> OK (task must be stopped before deletion)"

echo "[precondition] checking $CONTROL counts: its count must grow within a second and a half..."
C1=$((10#$(cat "$SHARED_DIR/control/count")))
sleep 1.5
C2=$((10#$(cat "$SHARED_DIR/control/count")))
if [ "$C2" -le "$C1" ]; then
    echo "  -> FAIL: the count of $CONTROL does not grow ($C1 -> $C2)"
    exit 1
fi
echo "  -> OK ($C1 -> $C2)"

echo "[precondition] all conditions met."
