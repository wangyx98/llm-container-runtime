#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: whatever the solution did to /etc/crictl.yaml, grade
# against containerd itself
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench74849789"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
TARGET_LIMIT=16777216

echo "[oracle] check 0: containerd must be up and answering on the CRI..."
for _ in $(seq 1 30); do
    sudo systemctl is-active --quiet containerd && $CRICTL info >/dev/null 2>&1 && break
    sleep 0.5
done
sudo systemctl is-active --quiet containerd || { echo "  -> FAIL: containerd is not active"; exit 1; }
$CRICTL info >/dev/null 2>&1 || { echo "  -> FAIL: crictl cannot talk to containerd"; exit 1; }
CONTAINER_ID=$(cat "$STATE_DIR/container_id" 2>/dev/null || true)
PID_REC=$(cat "$STATE_DIR/pid" 2>/dev/null || true)
START_REC=$(cat "$STATE_DIR/starttime" 2>/dev/null || true)
NONCE_REC=$(cat "$STATE_DIR/nonce" 2>/dev/null || true)
if [ -z "$CONTAINER_ID" ] || [ -z "$PID_REC" ] || [ -z "$START_REC" ] || [ -z "$NONCE_REC" ]; then
    echo "  -> FAIL: setup's recorded container id / pid / start time / nonce are missing"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: the workload container setup started must still exist and be"
echo "[oracle]          running: the limit has to be changed on the running container,"
echo "[oracle]          not by replacing it..."
STATE=$($CRICTL inspect -o go-template --template '{{.status.state}}' "$CONTAINER_ID" 2>/dev/null || true)
if [ -z "$STATE" ]; then
    echo "  -> FAIL: container $CONTAINER_ID does not exist any more (it was removed or replaced)"
    exit 1
fi
if [ "$STATE" != "CONTAINER_RUNNING" ]; then
    EXIT_CODE=$($CRICTL inspect -o go-template --template '{{.status.exitCode}}' "$CONTAINER_ID" 2>/dev/null || true)
    echo "  -> FAIL: container $CONTAINER_ID is not running (state $STATE, exit code ${EXIT_CODE:-unknown}); the workload did not survive"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: it must be the same workload process as before, not a restarted one..."
PID=$($CRICTL inspect -o go-template --template '{{.info.pid}}' "$CONTAINER_ID" 2>/dev/null || true)
START=$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" 2>/dev/null | awk '{print $20}')
if [ "$PID" != "$PID_REC" ] || [ "$START" != "$START_REC" ]; then
    echo "  -> FAIL: the workload process changed (host pid $PID_REC/start $START_REC before, $PID/${START:-gone} now): it was restarted"
    exit 1
fi
echo "  -> OK"

# Where the container's memory cgroup lives, and which files to read there.
# cgroup v2: a single hierarchy (memory.max / memory.current / memory.events);
# cgroup v1: the memory controller's own hierarchy (memory.limit_in_bytes / ...).
if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = "cgroup2fs" ]; then
    MODE="v2"
    REL=$(sudo awk -F: '$1 == 0 {print $3; exit}' "/proc/$PID/cgroup")
    CG="/sys/fs/cgroup$REL"
    LIMIT_FILE="$CG/memory.max"; USAGE_FILE="$CG/memory.current"; OOM_FILE="$CG/memory.events"
else
    MODE="v1"
    REL=$(sudo awk -F: '$2 ~ /(^|,)memory(,|$)/ {print $3; exit}' "/proc/$PID/cgroup")
    CG="/sys/fs/cgroup/memory$REL"
    LIMIT_FILE="$CG/memory.limit_in_bytes"; USAGE_FILE="$CG/memory.usage_in_bytes"; OOM_FILE="$CG/memory.oom_control"
fi

echo "[oracle] check 3: the cgroup memory limit of the container must be exactly"
echo "[oracle]          $TARGET_LIMIT bytes (cgroup $MODE: $LIMIT_FILE)..."
LIMIT=$(sudo cat "$LIMIT_FILE" 2>/dev/null || true)
USAGE=$(sudo cat "$USAGE_FILE" 2>/dev/null || true)
if [ "$LIMIT" != "$TARGET_LIMIT" ]; then
    echo "  -> FAIL: the container's memory limit is '${LIMIT:-unreadable}', expected $TARGET_LIMIT (current usage ${USAGE:-unknown})"
    exit 1
fi
echo "  -> OK (limit $LIMIT, usage ${USAGE:-unknown})"

echo "[oracle] check 4: the workload must still be doing its job: same heartbeat nonce,"
echo "[oracle]          and a counter that keeps advancing..."
NONCE=$(sed -n 's/^nonce=//p' "$DATA_DIR/status" 2>/dev/null || true)
if [ "$NONCE" != "$NONCE_REC" ]; then
    echo "  -> FAIL: the heartbeat nonce is '${NONCE:-missing}', expected '$NONCE_REC': this is not the original workload"
    exit 1
fi
C1=$(sed -n 's/^counter=//p' "$DATA_DIR/status" 2>/dev/null || true)
sleep 2.5
C2=$(sed -n 's/^counter=//p' "$DATA_DIR/status" 2>/dev/null || true)
if [ -z "$C1" ] || [ -z "$C2" ] || [ "$C2" -le "$C1" ]; then
    echo "  -> FAIL: the workload's heartbeat does not advance (counter '$C1' -> '$C2'): it is stuck or stopped"
    exit 1
fi
echo "  -> OK (counter $C1 -> $C2)"

echo "[oracle] check 5: the container must sit within its new limit, and nothing in it"
echo "[oracle]          may have been OOM-killed on the way..."
USAGE=$(sudo cat "$USAGE_FILE" 2>/dev/null || true)
OOM_KILLS=$(sudo awk '$1 == "oom_kill" {print $2; exit}' "$OOM_FILE" 2>/dev/null || true)
if [ -n "$USAGE" ] && [ "$USAGE" -gt "$TARGET_LIMIT" ]; then
    echo "  -> FAIL: usage $USAGE is above the limit $TARGET_LIMIT"
    exit 1
fi
if [ -n "$OOM_KILLS" ] && [ "$OOM_KILLS" -gt 0 ]; then
    echo "  -> FAIL: the kernel OOM-killed $OOM_KILLS process(es) in the container's cgroup"
    exit 1
fi
echo "  -> OK (usage ${USAGE:-unknown}, oom_kill ${OOM_KILLS:-0})"

echo "[oracle] all checks passed."
