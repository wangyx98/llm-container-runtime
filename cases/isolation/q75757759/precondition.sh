#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench75757759"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

st() { cat "$STATE_DIR/$1" 2>/dev/null || true; }
POD_ID=$(st pod_id); CONTAINER_ID=$(st container_id); IMAGE_ID=$(st image_id); PID_REC=$(st pid)
for v in "$POD_ID" "$CONTAINER_ID" "$IMAGE_ID" "$PID_REC"; do
    [ -n "$v" ] || { echo "[precondition] FAIL: setup's recorded ids are missing"; exit 1; }
done

echo "[precondition] checking containerd is up and answers on the CRI..."
sudo systemctl is-active --quiet containerd
$CRICTL info >/dev/null
echo "  -> OK"

echo "[precondition] checking the pod is ready and the container is running, from the"
echo "[precondition] image setup built, as the process setup recorded..."
[ "$($CRICTL inspectp -o go-template --template '{{.status.state}}' "$POD_ID" 2>/dev/null)" = "SANDBOX_READY" ] \
    || { echo "  -> FAIL: pod $POD_ID is not SANDBOX_READY"; exit 1; }
STATE=$($CRICTL inspect -o go-template --template '{{.status.state}}' "$CONTAINER_ID" 2>/dev/null || true)
if [ "$STATE" != "CONTAINER_RUNNING" ]; then
    echo "  -> FAIL: container $CONTAINER_ID is in state '${STATE:-unknown}', not CONTAINER_RUNNING"
    exit 1
fi
REF=$($CRICTL inspect -o go-template --template '{{.status.imageRef}}' "$CONTAINER_ID" 2>/dev/null || true)
if [ "$REF" != "sha256:$IMAGE_ID" ]; then
    echo "  -> FAIL: the container uses image '$REF', expected sha256:$IMAGE_ID"
    exit 1
fi
PID=$($CRICTL inspect -o go-template --template '{{.info.pid}}' "$CONTAINER_ID")
if [ "$PID" != "$PID_REC" ]; then
    echo "  -> FAIL: the container's host pid is $PID, setup recorded $PID_REC"
    exit 1
fi
echo "  -> OK (container $CONTAINER_ID, host pid $PID)"

echo "[precondition] checking the container has no capability at all (bounding set empty)"
echo "[precondition] and is not privileged..."
BND=$(sudo awk '$1 == "CapBnd:" {print $2}' "/proc/$PID/status")
if [ "$BND" != "0000000000000000" ]; then
    echo "  -> FAIL: the container's capability bounding set is $BND, expected 0000000000000000"
    exit 1
fi
PRIV=$($CRICTL inspect "$CONTAINER_ID" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sc = d["info"]["config"].get("linux", {}).get("security_context", {})
print("true" if sc.get("privileged") else "false")')
if [ "$PRIV" != "false" ]; then
    echo "  -> FAIL: the container is privileged"
    exit 1
fi
echo "  -> OK (CapBnd $BND, not privileged)"

echo "[precondition] checking the symptom: ping inside the container cannot be executed..."
OUT=$(sudo timeout -k 5 30 crictl --runtime-endpoint "unix://$SOCK" exec "$CONTAINER_ID" /usr/bin/ping -c 1 127.0.0.1 </dev/null 2>&1) && RC=0 || RC=$?
if [ "$RC" -eq 0 ]; then
    echo "  -> FAIL: ping worked although every capability is dropped: $OUT"
    exit 1
fi
if ! echo "$OUT" | grep -qi "operation not permitted"; then
    echo "  -> FAIL: ping failed, but not with 'operation not permitted' (exit $RC): $(echo "$OUT" | tail -3)"
    exit 1
fi
echo "  -> OK (exit $RC: $(echo "$OUT" | grep -i 'not permitted' | head -1))"

echo "[precondition] all checks passed."
