#!/bin/bash
set -e

CASE_ID="bench70710123"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CONTAINER_NAME="$CASE_ID"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
PORT=7070
URL="http://host.docker.internal:$PORT/"

echo "[oracle] check 0: containerd must be up and answering..."
if ! sudo ctr version >/dev/null 2>&1; then
    echo "  -> FAIL: containerd does not answer"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: a container named '$CONTAINER_NAME' must exist in the default namespace, made"
echo "[oracle]          from the image, with a RUNNING task..."
# a container made by `nerdctl run --name` keeps the name in the label nerdctl/name and has a hash
# as its containerd id; a container made by ctr has the name as its id
CID=""
IMAGE_OF=""
for c in $(sudo ctr containers ls -q 2>/dev/null); do
    FOUND=$(sudo ctr containers info "$c" 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
info = json.load(sys.stdin)
if info.get("ID") == name or (info.get("Labels") or {}).get("nerdctl/name") == name:
    print(info.get("Image", ""))
else:
    sys.exit(1)' "$CONTAINER_NAME" 2>/dev/null) || continue
    CID="$c"
    IMAGE_OF="$FOUND"
    break
done
if [ -z "$CID" ]; then
    echo "  -> FAIL: no container named '$CONTAINER_NAME' in the default namespace (containers: $(sudo ctr containers ls -q 2>/dev/null | tr '\n' ' '))"
    exit 1
fi
if [ "$IMAGE_OF" != "$IMAGE_REF" ]; then
    echo "  -> FAIL: container '$CONTAINER_NAME' was made from '$IMAGE_OF', expected $IMAGE_REF"
    exit 1
fi
PID=""
for _ in $(seq 1 20); do
    PID=$(sudo ctr tasks ls 2>/dev/null | awk -v n="$CID" '$1==n && $3=="RUNNING" {print $2}')
    [ -n "$PID" ] && break
    sleep 0.5
done
if [ -z "$PID" ]; then
    echo "  -> FAIL: container '$CONTAINER_NAME' has no RUNNING task (tasks: $(sudo ctr tasks ls 2>/dev/null | tr '\n' ' '))"
    exit 1
fi
echo "  -> OK (id $CID, host pid $PID)"

echo "[oracle] check 2: the image's own program, run in the network and filesystem namespaces of"
echo "[oracle]          that container, must get HTTP 200 from $URL ..."
BODY_FILE="$STATE_DIR/answer.txt"
ERR_FILE="$STATE_DIR/probe.err"
RC=0
for _ in $(seq 1 6); do
    RC=0
    timeout -k 3 20 sudo nsenter -t "$PID" -n -m /usr/bin/probe fetch "$URL" >"$BODY_FILE" 2>"$ERR_FILE" </dev/null || RC=$?
    [ "$RC" = "0" ] && break
    # the name does not resolve: nothing will change within a second or two
    [ "$RC" = "3" ] && break
    sleep 1
done
if [ "$RC" != "0" ]; then
    case "$RC" in
        3) WHY="the name does not resolve inside the container" ;;
        4) WHY="the name resolves, but the connection fails" ;;
        5) WHY="something answers, but not with HTTP 200" ;;
        *) WHY="the probe could not run (exit $RC)" ;;
    esac
    echo "  -> FAIL: from inside container '$CONTAINER_NAME', $URL does not work: $WHY: $(tr '\n' ' ' < "$ERR_FILE")"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: the answer must come from the host's test service: it carries the run's token..."
TOKEN=$(cat "$STATE_DIR/token")
GOT_TOKEN=$(sed -n 's/^token=//p' "$BODY_FILE" | head -1)
if [ "$GOT_TOKEN" != "$TOKEN" ]; then
    echo "  -> FAIL: the answer does not carry the token of the host's test service (got '${GOT_TOKEN:-nothing}'): something else answers inside the container"
    exit 1
fi
echo "  -> OK (answered by the host's test service, which saw the request come from $(sed -n 's/^peer=//p' "$BODY_FILE" | head -1))"

echo "[oracle] ALL CHECKS PASSED"
