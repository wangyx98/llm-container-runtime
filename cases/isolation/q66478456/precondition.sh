#!/bin/bash
set -e

CASE_ID="bench66478456"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
CONTAINER_NAME="$CASE_ID"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
HOST_ID=5000

echo "[precondition] checking the container '$CONTAINER_NAME' exists, was made from the image and"
echo "[precondition] its task is RUNNING..."
IMAGE_OF=$(sudo ctr containers info "$CONTAINER_NAME" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Image",""))' 2>/dev/null || true)
if [ "$IMAGE_OF" != "$IMAGE_REF" ]; then
    echo "  -> FAIL: container '$CONTAINER_NAME' does not exist or was made from '$IMAGE_OF'"
    exit 1
fi
PID=$(sudo ctr tasks ls 2>/dev/null | awk -v n="$CONTAINER_NAME" '$1==n && $3=="RUNNING" {print $2}')
if [ -z "$PID" ]; then
    echo "  -> FAIL: no RUNNING task named '$CONTAINER_NAME'"
    exit 1
fi
echo "  -> OK (host pid $PID)"

echo "[precondition] checking the symptom: the main process is root on the host and shares the"
echo "[precondition] host's user namespace, with identity uid and gid maps (the --uidmap was"
echo "[precondition] not applied)..."
UIDS=$(sudo awk '/^Uid:/{print $2,$3,$4,$5}' "/proc/$PID/status")
GIDS=$(sudo awk '/^Gid:/{print $2,$3,$4,$5}' "/proc/$PID/status")
if [ "$UIDS" != "0 0 0 0" ] || [ "$GIDS" != "0 0 0 0" ]; then
    echo "  -> FAIL: the main process runs as uids '$UIDS' gids '$GIDS' on the host, expected root"
    exit 1
fi
if [ "$(sudo readlink "/proc/$PID/ns/user")" != "$(readlink /proc/$$/ns/user)" ]; then
    echo "  -> FAIL: the container already has a user namespace of its own"
    exit 1
fi
if [ "$(sudo awk '{print $1,$2}' "/proc/$PID/uid_map" | head -1)" != "0 0" ]; then
    echo "  -> FAIL: the uid map is not the identity map"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the host data dir belongs to $HOST_ID:$HOST_ID and the file the"
echo "[precondition] container wrote belongs to root..."
test -f "$DATA_DIR/inside.txt"
if [ "$(stat -c '%u:%g' "$DATA_DIR")" != "$HOST_ID:$HOST_ID" ]; then
    echo "  -> FAIL: $DATA_DIR is owned by $(stat -c '%u:%g' "$DATA_DIR")"
    exit 1
fi
if [ "$(stat -c '%u:%g' "$DATA_DIR/inside.txt")" != "0:0" ]; then
    echo "  -> FAIL: inside.txt is owned by $(stat -c '%u:%g' "$DATA_DIR/inside.txt"), expected 0:0"
    exit 1
fi
grep -q '^uid=0$' "$DATA_DIR/inside.txt"
grep -qx "token=$(cat "$STATE_DIR/token")" "$DATA_DIR/inside.txt"
echo "  -> OK"

echo "[precondition] PASS - a container whose root is root on the host, writing root-owned files."
