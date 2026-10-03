#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench65393959"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"

st() { cat "$STATE_DIR/$1" 2>/dev/null || true; }
POD_ID=$(st pod_id); CONTAINER_ID=$(st container_id); IMAGE_ID=$(st image_id); PID_REC=$(st pid)
OWNER_UID=$(st uid); OWNER_GID=$(st gid); OWNER_NAME=$(st name)
for v in "$POD_ID" "$CONTAINER_ID" "$IMAGE_ID" "$PID_REC" "$OWNER_UID" "$OWNER_GID" "$OWNER_NAME"; do
    [ -n "$v" ] || { echo "[precondition] FAIL: setup's recorded ids are missing"; exit 1; }
done

echo "[precondition] checking containerd is up and answers on the CRI..."
sudo systemctl is-active --quiet containerd
$CRICTL info >/dev/null
echo "  -> OK"

echo "[precondition] checking the pod is ready and the container is running, from the"
echo "[precondition] image setup built, with its main process running as root..."
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
RUID=$(sudo awk '$1 == "Uid:" {print $2}' "/proc/$PID/status")
if [ "$RUID" != "0" ]; then
    echo "  -> FAIL: the container's main process runs as uid $RUID, not root"
    exit 1
fi
echo "  -> OK (container $CONTAINER_ID, host pid $PID, uid $RUID)"

echo "[precondition] checking the data is owned by $OWNER_UID:$OWNER_GID and nothing has been"
echo "[precondition] written to it yet..."
OWN=$(sudo stat -c '%u:%g' "$DATA_DIR/state")
if [ "$OWN" != "$OWNER_UID:$OWNER_GID" ]; then
    echo "  -> FAIL: $DATA_DIR/state is owned by $OWN, expected $OWNER_UID:$OWNER_GID"
    exit 1
fi
if sudo test -e "$DATA_DIR/done"; then
    echo "  -> FAIL: $DATA_DIR/done exists before the solution ran"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking ctr (namespace k8s.io) sees the same container..."
if ! sudo ctr -n k8s.io containers ls -q 2>/dev/null | grep -qxF "$CONTAINER_ID"; then
    echo "  -> FAIL: 'ctr -n k8s.io containers ls' does not list $CONTAINER_ID"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the symptom: run as root (what crictl exec gives), the script"
echo "[precondition] refuses and writes nothing..."
OUT=$(sudo timeout -k 5 30 crictl --runtime-endpoint "unix://$SOCK" exec "$CONTAINER_ID" /usr/bin/rotate </dev/null 2>&1) && RC=0 || RC=$?
if [ "$RC" -eq 0 ]; then
    echo "  -> FAIL: the script ran as root although the data belongs to uid $OWNER_UID: $OUT"
    exit 1
fi
if ! echo "$OUT" | grep -q "refusing to run"; then
    echo "  -> FAIL: the script failed, but not with its 'refusing to run' message (exit $RC): $(echo "$OUT" | tail -3)"
    exit 1
fi
if sudo test -e "$DATA_DIR/done"; then
    echo "  -> FAIL: the refused run still wrote $DATA_DIR/done"
    exit 1
fi
echo "  -> OK ($(echo "$OUT" | grep 'refusing to run' | head -1))"

echo "[precondition] all checks passed."
