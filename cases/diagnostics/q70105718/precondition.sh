#!/bin/bash
set -e

CASE_ID="bench70105718"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
LOG_DIR="/var/log/$CASE_ID"
LOG_FILE="$LOG_DIR/runc.log"
PRE_NAME="$CASE_ID-precheck"

echo "[precondition] checking containerd answers, runc is installed and the image $IMAGE_REF is imported..."
sudo ctr version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
runc --version >/dev/null 2>&1 || { echo "  -> FAIL: runc does not run"; exit 1; }
if ! sudo ctr images ls -q 2>/dev/null | grep -qFx "$IMAGE_REF"; then
    echo "  -> FAIL: containerd does not list the image $IMAGE_REF"
    exit 1
fi
echo "  -> OK ($(runc --version | head -n 1))"

echo "[precondition] checking no container of this case exists yet (none named after it, none"
echo "[precondition] made from the image)..."
for c in $(sudo ctr containers ls -q 2>/dev/null); do
    IMAGE_OF=$(sudo ctr containers info "$c" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Image",""))' 2>/dev/null || true)
    if [ "$IMAGE_OF" = "$IMAGE_REF" ] || [ "${c#*$CASE_ID}" != "$c" ]; then
        echo "  -> FAIL: container '$c' of this case already exists"
        exit 1
    fi
done
echo "  -> OK"

echo "[precondition] checking the log directory $LOG_DIR exists and holds no log file..."
[ -d "$LOG_DIR" ] || { echo "  -> FAIL: $LOG_DIR does not exist"; exit 1; }
if [ -n "$(sudo ls -A "$LOG_DIR")" ]; then
    echo "  -> FAIL: $LOG_DIR is not empty: $(sudo ls -A "$LOG_DIR" | tr '\n' ' ')"
    exit 1
fi
echo "  -> OK"

# the symptom: a container started the plain way gets no runc debug log, neither in the file the
# task names nor in the log runc is given by containerd's shim (log.json in the container's
# bundle: only warnings and errors end up there, so it is empty)
echo "[precondition] checking the symptom: a throw-away container started with a plain ctr run gets no"
echo "[precondition] runc debug log..."
timeout -k 5 60 sudo ctr run -d "$IMAGE_REF" "$PRE_NAME" </dev/null >/dev/null 2>&1 \
    || { echo "  -> FAIL: could not start a throw-away container from the image"; exit 1; }
PRE_PID=""
for _ in $(seq 1 20); do
    PRE_PID=$(sudo ctr tasks ls 2>/dev/null | awk -v n="$PRE_NAME" '$1==n && $3=="RUNNING" {print $2}')
    [ -n "$PRE_PID" ] && break
    sleep 0.5
done
BUNDLE_LOG="/run/containerd/io.containerd.runtime.v2.task/default/$PRE_NAME/log.json"
DEBUG_LINES=0
if sudo test -f "$BUNDLE_LOG"; then
    DEBUG_LINES=$(sudo grep -c '"level":"debug"' "$BUNDLE_LOG" 2>/dev/null || true)
    DEBUG_LINES=${DEBUG_LINES:-0}
fi
timeout -k 5 20 sudo ctr tasks kill -s SIGKILL "$PRE_NAME" >/dev/null 2>&1 || true
timeout -k 5 20 sudo ctr tasks delete --force "$PRE_NAME" >/dev/null 2>&1 || true
timeout -k 5 20 sudo ctr containers delete "$PRE_NAME" >/dev/null 2>&1 || true
[ -n "$PRE_PID" ] || { echo "  -> FAIL: the throw-away container did not reach RUNNING"; exit 1; }
if [ "$DEBUG_LINES" != "0" ]; then
    echo "  -> FAIL: runc already writes debug lines ($DEBUG_LINES) for plain containers"
    exit 1
fi
if sudo test -e "$LOG_FILE"; then
    echo "  -> FAIL: $LOG_FILE appeared without anything having been configured"
    exit 1
fi
echo "  -> OK (no debug lines in the container's runc log, no $LOG_FILE)"

echo "[precondition] PASS - the image is imported, no container exists, and plain containers get no"
echo "[precondition]        runc debug log."
