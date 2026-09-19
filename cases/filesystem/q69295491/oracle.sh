#!/bin/bash
set -e

POD_NAME="bench69295491-pod"
CONTAINER_NAME="bench69295491"
HOST_DIR="/tmp/bench69295491/hostdir"

echo "[oracle] check 0: crictl must be talking to a genuine, running CRI-O backend..."
RUNTIME_ENDPOINT=$(grep -E '^runtime-endpoint' /etc/crictl.yaml 2>/dev/null | awk '{print $2}')
case "$RUNTIME_ENDPOINT" in
    *crio*) echo "  -> OK (runtime-endpoint=$RUNTIME_ENDPOINT)" ;;
    *) echo "  -> FAIL: runtime-endpoint is '$RUNTIME_ENDPOINT', expected the CRI-O socket"; exit 1 ;;
esac
if ! sudo systemctl is-active --quiet crio.service; then
    echo "  -> FAIL: crio.service is not active"
    exit 1
fi

echo "[oracle] check 1: pod sandbox '$POD_NAME' must be READY, container"
echo "[oracle]          '$CONTAINER_NAME' must be RUNNING and belong to it..."
POD_ID=$(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null | head -1)
if [ -z "$POD_ID" ]; then
    echo "  -> FAIL: no pod sandbox named '$POD_NAME' found"
    exit 1
fi
POD_STATE=$(sudo crictl inspectp "$POD_ID" 2>/dev/null | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('status', {}).get('state', ''))
except Exception:
    print('')
")
if [ "$POD_STATE" != "SANDBOX_READY" ]; then
    echo "  -> FAIL: pod sandbox state is '${POD_STATE:-<unknown>}', expected 'SANDBOX_READY'"
    exit 1
fi

CTR_ID=$(sudo crictl ps --name "$CONTAINER_NAME" -q 2>/dev/null | head -1)
if [ -z "$CTR_ID" ]; then
    echo "  -> FAIL: no running container named '$CONTAINER_NAME' found"
    exit 1
fi
CTR_STATE=$(sudo crictl inspect "$CTR_ID" 2>/dev/null | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('status', {}).get('state', ''))
except Exception:
    print('')
")
if [ "$CTR_STATE" != "CONTAINER_RUNNING" ]; then
    echo "  -> FAIL: container state is '${CTR_STATE:-<unknown>}', expected 'CONTAINER_RUNNING'"
    exit 1
fi
echo "  -> OK (pod $POD_ID READY, container $CTR_ID RUNNING)"

echo "[oracle] check 2: /data/data.txt inside the container must match the"
echo "[oracle]          host file's CURRENT content..."
HOST_CONTENT=$(cat "$HOST_DIR/data.txt")
IN_CTR_CONTENT=$(sudo crictl exec "$CTR_ID" cat /data/data.txt 2>/dev/null || true)
if [ "$IN_CTR_CONTENT" != "$HOST_CONTENT" ]; then
    echo "  -> FAIL: expected '$HOST_CONTENT' inside the container, got '$IN_CTR_CONTENT'"
    exit 1
fi
echo "  -> OK ($IN_CTR_CONTENT)"

echo "[oracle] check 3 (anti-cheat): this must be a LIVE bind mount, not a"
echo "[oracle]          one-time copy taken at container-creation time. Changing"
echo "[oracle]          the HOST file now, with NO further action inside the"
echo "[oracle]          container, must be immediately visible from inside..."
UPDATED_MARKER="SO69295491_LIVE_MOUNT_CHECK_$$"
echo "$UPDATED_MARKER" > "$HOST_DIR/data.txt"
IN_CTR_AFTER_HOST_EDIT=$(sudo crictl exec "$CTR_ID" cat /data/data.txt 2>/dev/null || true)
if [ "$IN_CTR_AFTER_HOST_EDIT" != "$UPDATED_MARKER" ]; then
    echo "  -> FAIL: host file was updated to '$UPDATED_MARKER' but the container"
    echo "     still sees '$IN_CTR_AFTER_HOST_EDIT'. This means /data is NOT a real"
    echo "     bind mount -- it was most likely a one-time file copy (e.g. via"
    echo "     /proc/<pid>/root) taken once at setup/solution time instead of a"
    echo "     genuine, live host<->container mount."
    exit 1
fi
echo "  -> OK (host edit propagated into the container instantly: $IN_CTR_AFTER_HOST_EDIT)"

echo "[oracle] check 4: the mount must also work in the OTHER direction --"
echo "[oracle]          a file written from INSIDE the container must appear"
echo "[oracle]          on the host, proving it's a real mount, not a"
echo "[oracle]          read-only/one-way trick..."
WRITE_MARKER="SO69295491_FROM_CONTAINER_$$"
if ! sudo crictl exec "$CTR_ID" sh -c "echo '$WRITE_MARKER' > /data/from_container.txt" >/dev/null 2>&1; then
    echo "  -> FAIL: could not write a new file from inside the container into /data"
    exit 1
fi
if [ ! -f "$HOST_DIR/from_container.txt" ]; then
    echo "  -> FAIL: /data/from_container.txt written inside the container never"
    echo "     appeared on the host at $HOST_DIR/from_container.txt"
    exit 1
fi
HOST_SIDE_CONTENT=$(sudo cat "$HOST_DIR/from_container.txt")
if [ "$HOST_SIDE_CONTENT" != "$WRITE_MARKER" ]; then
    echo "  -> FAIL: host-side content '$HOST_SIDE_CONTENT' does not match what the"
    echo "     container wrote ('$WRITE_MARKER')"
    exit 1
fi
echo "  -> OK (container write visible on host: $HOST_SIDE_CONTENT)"

echo "[oracle] ALL CHECKS PASSED"
