#!/bin/bash
set -e

CASE_ID="bench66478456"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
CONTAINER_NAME="$CASE_ID"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
HOST_ID=5000

echo "[oracle] check 0: containerd must be up and answering..."
if ! sudo ctr version >/dev/null 2>&1; then
    echo "  -> FAIL: containerd does not answer"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: the container '$CONTAINER_NAME' must exist in the default namespace, made"
echo "[oracle]          from the image, with a RUNNING task..."
IMAGE_OF=$(sudo ctr containers info "$CONTAINER_NAME" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Image",""))' 2>/dev/null || true)
if [ "$IMAGE_OF" != "$IMAGE_REF" ]; then
    echo "  -> FAIL: container '$CONTAINER_NAME' does not exist in the default namespace or was made from '$IMAGE_OF', expected $IMAGE_REF"
    exit 1
fi
PID=""
for _ in $(seq 1 20); do
    PID=$(sudo ctr tasks ls 2>/dev/null | awk -v n="$CONTAINER_NAME" '$1==n && $3=="RUNNING" {print $2}')
    [ -n "$PID" ] && break
    sleep 0.5
done
if [ -z "$PID" ]; then
    echo "  -> FAIL: no RUNNING task named '$CONTAINER_NAME' (tasks: $(sudo ctr tasks ls 2>/dev/null | tr '\n' ' '))"
    exit 1
fi
echo "  -> OK (host pid $PID)"

echo "[oracle] check 2: seen from the host, the container's main process must run as uid and"
echo "[oracle]          gid $HOST_ID (what 'ps -eo uid,gid,cmd' shows for it)..."
UIDS=$(sudo awk '/^Uid:/{print $2,$3,$4,$5}' "/proc/$PID/status")
GIDS=$(sudo awk '/^Gid:/{print $2,$3,$4,$5}' "/proc/$PID/status")
if [ "$UIDS" != "$HOST_ID $HOST_ID $HOST_ID $HOST_ID" ]; then
    echo "  -> FAIL: on the host the main process runs with uids '$UIDS', expected $HOST_ID (the uid map was not applied as asked)"
    exit 1
fi
if [ "$GIDS" != "$HOST_ID $HOST_ID $HOST_ID $HOST_ID" ]; then
    echo "  -> FAIL: on the host the main process runs with gids '$GIDS', expected $HOST_ID"
    exit 1
fi
echo "  -> OK (uid $HOST_ID, gid $HOST_ID)"

echo "[oracle] check 3: inside the container, root must still be root: /usr/bin/id run in it..."
INSIDE=$(timeout -k 5 30 sudo ctr tasks exec --exec-id "$CASE_ID-oracle-id" "$CONTAINER_NAME" /usr/bin/id </dev/null 2>/dev/null || true)
if [ "$INSIDE" != "uid=0 gid=0" ]; then
    echo "  -> FAIL: /usr/bin/id inside the container printed '${INSIDE:-nothing}', expected 'uid=0 gid=0'"
    exit 1
fi
echo "  -> OK ($INSIDE)"

echo "[oracle] check 4: the process must live in a user namespace of its own, whose uid map and"
echo "[oracle]          gid map send container id 0 to host id $HOST_ID..."
if [ "$(sudo readlink "/proc/$PID/ns/user")" = "$(readlink /proc/$$/ns/user)" ]; then
    echo "  -> FAIL: the process shares the host's user namespace (the one this script itself runs in)"
    exit 1
fi
for map in uid_map gid_map; do
    if ! sudo awk -v h="$HOST_ID" '$1==0 && $2==h && $3>=1 {f=1} END{exit !f}' "/proc/$PID/$map"; then
        echo "  -> FAIL: /proc/$PID/$map does not map container id 0 to host id $HOST_ID: $(sudo tr -s ' ' < "/proc/$PID/$map" | tr '\n' ';')"
        exit 1
    fi
done
echo "  -> OK ($(sudo tr -s ' ' < "/proc/$PID/uid_map" | head -1), $(sudo tr -s ' ' < "/proc/$PID/gid_map" | head -1))"

echo "[oracle] check 5: on the host, $DATA_DIR/inside.txt must have been written by the container's"
echo "[oracle]          own program after the fix started, as root inside and owned by"
echo "[oracle]          $HOST_ID:$HOST_ID outside..."
F="$DATA_DIR/inside.txt"
TOKEN=$(cat "$STATE_DIR/token")
T0=$(cat "$STATE_DIR/t0")
for _ in $(seq 1 20); do
    [ -f "$F" ] && grep -qx "token=$TOKEN" "$F" && [ "$(stat -c '%u' "$F")" = "$HOST_ID" ] && break
    sleep 0.5
done
if [ ! -f "$F" ]; then
    echo "  -> FAIL: $F does not exist"
    exit 1
fi
if ! grep -qx "token=$TOKEN" "$F"; then
    echo "  -> FAIL: $F does not carry the token of the image's program: it was not written by the container"
    exit 1
fi
OWNER=$(stat -c '%u:%g' "$F")
if [ "$OWNER" != "$HOST_ID:$HOST_ID" ]; then
    echo "  -> FAIL: on the host, $F belongs to $OWNER, expected $HOST_ID:$HOST_ID"
    exit 1
fi
TS=$(sed -n 's/^ts=//p' "$F")
if [ -z "$TS" ] || [ "$TS" -le "$T0" ]; then
    echo "  -> FAIL: $F is older than the setup of this run (ts=${TS:-none}): the container that is running now did not write it"
    exit 1
fi
if ! grep -qx 'uid=0' "$F" || ! grep -qx 'gid=0' "$F"; then
    echo "  -> FAIL: the program inside the container saw ids other than 0:0: $(tr '\n' ' ' < "$F")"
    exit 1
fi
echo "  -> OK (owned by $OWNER, written inside as uid=0 gid=0 after the fix)"

echo "[oracle] ALL CHECKS PASSED"
