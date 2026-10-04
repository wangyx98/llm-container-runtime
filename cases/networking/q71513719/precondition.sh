#!/bin/bash
set -e

CASE_ID="bench71513719"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CONTAINER_NAME="$CASE_ID"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
PORT=8085

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

echo "[precondition] checking the container has a network namespace of its own (not the host's)"
echo "[precondition] and its server answers inside it..."
if [ "$(sudo readlink "/proc/$PID/ns/net")" = "$(readlink /proc/$$/ns/net)" ]; then
    echo "  -> FAIL: the container already shares the host's network namespace"
    exit 1
fi
TOKEN=$(cat "$STATE_DIR/token")
INSIDE=$(sudo nsenter -t "$PID" -n curl -sS --noproxy '*' --max-time 3 "http://127.0.0.1:$PORT/" 2>&1 || true)
if ! echo "$INSIDE" | grep -qFx "token=$TOKEN"; then
    echo "  -> FAIL: the server does not answer inside the container's network namespace: $INSIDE"
    exit 1
fi
if ! echo "$INSIDE" | grep -qFx "pidns=$(sudo readlink "/proc/$PID/ns/pid")"; then
    echo "  -> FAIL: the answer does not name the container's pid namespace: $INSIDE"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the symptom: from the host, port $PORT is not reachable..."
if OUT=$(curl -sS --noproxy '*' --max-time 3 "http://127.0.0.1:$PORT/" 2>&1); then
    echo "  -> FAIL: the host already gets an answer on 127.0.0.1:$PORT: $OUT"
    exit 1
fi
echo "  -> OK ($OUT)"

echo "[precondition] checking the tools the task names are there: ctr, CNI plugins, nerdctl..."
[ -x /opt/cni/bin/bridge ] && [ -x /opt/cni/bin/portmap ] || { echo "  -> FAIL: CNI plugins missing in /opt/cni/bin"; exit 1; }
if [ "${BENCH_NO_NERDCTL:-0}" = "1" ]; then
    echo "  -> OK (BENCH_NO_NERDCTL=1: nerdctl not required on this machine)"
else
    command -v nerdctl >/dev/null 2>&1 || { echo "  -> FAIL: nerdctl is not installed"; exit 1; }
    echo "  -> OK ($(nerdctl --version 2>/dev/null))"
fi

echo "[precondition] PASS - a container whose web server listens on $PORT inside its own network"
echo "[precondition]        namespace, with nothing on the host answering that port."
