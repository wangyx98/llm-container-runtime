#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench74849789"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
INITIAL_LIMIT=134217728
TARGET_LIMIT=16777216

echo "[precondition] checking containerd is up and answers on the CRI..."
sudo systemctl is-active --quiet containerd
$CRICTL info >/dev/null
echo "  -> OK"

CONTAINER_ID=$(cat "$STATE_DIR/container_id")
PID_REC=$(cat "$STATE_DIR/pid")

echo "[precondition] checking the workload container setup started is running, and its"
echo "[precondition] process is the one that was recorded..."
STATE=$($CRICTL inspect -o go-template --template '{{.status.state}}' "$CONTAINER_ID" 2>/dev/null || true)
if [ "$STATE" != "CONTAINER_RUNNING" ]; then
    echo "  -> FAIL: container $CONTAINER_ID is in state '${STATE:-unknown}', not CONTAINER_RUNNING"
    exit 1
fi
PID=$($CRICTL inspect -o go-template --template '{{.info.pid}}' "$CONTAINER_ID")
if [ "$PID" != "$PID_REC" ]; then
    echo "  -> FAIL: the container's host pid is $PID, setup recorded $PID_REC"
    exit 1
fi
echo "  -> OK (container $CONTAINER_ID, host pid $PID)"

# Where the container's memory cgroup lives, and which files to read there.
# cgroup v2: a single hierarchy (memory.max / memory.current / memory.events);
# cgroup v1: the memory controller's own hierarchy (memory.limit_in_bytes / ...).
if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = "cgroup2fs" ]; then
    MODE="v2"
    REL=$(sudo awk -F: '$1 == 0 {print $3; exit}' "/proc/$PID/cgroup")
    CG="/sys/fs/cgroup$REL"
    LIMIT_FILE="$CG/memory.max"; USAGE_FILE="$CG/memory.current"
else
    MODE="v1"
    REL=$(sudo awk -F: '$2 ~ /(^|,)memory(,|$)/ {print $3; exit}' "/proc/$PID/cgroup")
    CG="/sys/fs/cgroup/memory$REL"
    LIMIT_FILE="$CG/memory.limit_in_bytes"; USAGE_FILE="$CG/memory.usage_in_bytes"
fi

echo "[precondition] checking the container's memory limit is the 128 MiB it was created"
echo "[precondition] with, and that it already uses more than the 16 MiB the question"
echo "[precondition] wants to set (host uses cgroup $MODE)..."
LIMIT=$(sudo cat "$LIMIT_FILE" 2>/dev/null || true)
USAGE=$(sudo cat "$USAGE_FILE" 2>/dev/null || true)
if [ "$LIMIT" != "$INITIAL_LIMIT" ]; then
    echo "  -> FAIL: the cgroup memory limit is '${LIMIT:-unreadable}' ($LIMIT_FILE), expected $INITIAL_LIMIT"
    exit 1
fi
if [ -z "$USAGE" ] || [ "$USAGE" -le "$TARGET_LIMIT" ]; then
    echo "  -> FAIL: the container uses '${USAGE:-unreadable}' bytes, not more than $TARGET_LIMIT"
    exit 1
fi
echo "  -> OK (limit $LIMIT, usage $USAGE)"

echo "[precondition] checking the workload is alive and holding its 48 MiB buffer"
echo "[precondition] (heartbeat counter must advance)..."
C1=$(sed -n 's/^counter=//p' "$DATA_DIR/status" 2>/dev/null || true)
sleep 2
C2=$(sed -n 's/^counter=//p' "$DATA_DIR/status" 2>/dev/null || true)
if [ -z "$C1" ] || [ -z "$C2" ] || [ "$C2" -le "$C1" ]; then
    echo "  -> FAIL: the heartbeat does not advance (counter '$C1' -> '$C2')"
    exit 1
fi
if ! grep -qx "buffer_mib=48" "$DATA_DIR/status"; then
    echo "  -> FAIL: the workload does not hold its 48 MiB buffer"
    exit 1
fi
echo "  -> OK (counter $C1 -> $C2)"

echo "[precondition] checking the symptom itself: asking for 16 MiB while 48 MiB are in"
echo "[precondition] use must not work..."
if [ "$MODE" = "v1" ]; then
    # cgroup v1 refuses a limit below the current usage (EBUSY), which runc
    # reports as 'unable to set memory limit'. The refused request changes nothing,
    # so it is safe to try it here.
    OUT=$($CRICTL update --memory "$TARGET_LIMIT" "$CONTAINER_ID" 2>&1) && RC=0 || RC=$?
    if [ "$RC" -eq 0 ]; then
        echo "  -> FAIL: crictl update --memory $TARGET_LIMIT succeeded although usage is $USAGE"
        exit 1
    fi
    if ! echo "$OUT" | grep -q "unable to set memory limit"; then
        echo "  -> FAIL: crictl update failed, but not with 'unable to set memory limit': $OUT"
        exit 1
    fi
    LIMIT_AFTER=$(sudo cat "$LIMIT_FILE")
    if [ "$LIMIT_AFTER" != "$INITIAL_LIMIT" ]; then
        echo "  -> FAIL: the refused update still changed the limit to $LIMIT_AFTER"
        exit 1
    fi
    echo "  -> OK (refused: unable to set memory limit to $TARGET_LIMIT, current usage $USAGE; limit unchanged)"
else
    # cgroup v2 does not refuse: writing memory.max below the usage makes the
    # kernel reclaim and, when there is nothing left to reclaim, OOM-kill the
    # workload. That would destroy the setup, so it is not tried here.
    echo "  -> OK (not tried: on cgroup v2 the kernel would OOM-kill the workload instead of refusing)"
fi

echo "[precondition] all checks passed."
