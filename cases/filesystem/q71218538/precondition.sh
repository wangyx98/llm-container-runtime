#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench71218538"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"

st() { cat "$STATE_DIR/$1" 2>/dev/null || true; }
POD_ID=$(st pod_id); ACTIVE_ID=$(st container_active); JOB_ID=$(st container_job); OLD_ID=$(st container_old)
IMG_ACTIVE=$(st image_id_active); IMG_STOPPED=$(st image_id_stopped); IMG_UNUSED=$(st image_id_unused)
PID_REC=$(st pid)
for v in "$POD_ID" "$ACTIVE_ID" "$JOB_ID" "$OLD_ID" "$IMG_ACTIVE" "$IMG_STOPPED" "$IMG_UNUSED" "$PID_REC"; do
    [ -n "$v" ] || { echo "[precondition] FAIL: setup's recorded ids are missing"; exit 1; }
done

echo "[precondition] checking containerd is up and answers on the CRI..."
sudo systemctl is-active --quiet containerd
$CRICTL info >/dev/null
echo "  -> OK"

echo "[precondition] checking the pod sandbox is ready and the workload container is running,"
echo "[precondition] as the process setup started, with its heartbeat advancing..."
[ "$($CRICTL inspectp -o go-template --template '{{.status.state}}' "$POD_ID" 2>/dev/null)" = "SANDBOX_READY" ] \
    || { echo "  -> FAIL: pod $POD_ID is not SANDBOX_READY"; exit 1; }
STATE=$($CRICTL inspect -o go-template --template '{{.status.state}}' "$ACTIVE_ID" 2>/dev/null || true)
if [ "$STATE" != "CONTAINER_RUNNING" ]; then
    echo "  -> FAIL: container $ACTIVE_ID is in state '${STATE:-unknown}', not CONTAINER_RUNNING"
    exit 1
fi
PID=$($CRICTL inspect -o go-template --template '{{.info.pid}}' "$ACTIVE_ID")
if [ "$PID" != "$PID_REC" ]; then
    echo "  -> FAIL: the workload's host pid is $PID, setup recorded $PID_REC"
    exit 1
fi
C1=$(sed -n 's/^counter=//p' "$DATA_DIR/status" 2>/dev/null || true)
sleep 2
C2=$(sed -n 's/^counter=//p' "$DATA_DIR/status" 2>/dev/null || true)
if [ -z "$C1" ] || [ -z "$C2" ] || [ "$C2" -le "$C1" ]; then
    echo "  -> FAIL: the heartbeat does not advance (counter '$C1' -> '$C2')"
    exit 1
fi
echo "  -> OK (container $ACTIVE_ID, host pid $PID, counter $C1 -> $C2)"

echo "[precondition] checking the two stopped containers are there: both exited, one from"
echo "[precondition] the 'stopped' image and one from the workload's own image..."
for pair in "$JOB_ID:$IMG_STOPPED" "$OLD_ID:$IMG_ACTIVE"; do
    CID=${pair%%:*}; WANT=${pair##*:}
    STATE=$($CRICTL inspect -o go-template --template '{{.status.state}}' "$CID" 2>/dev/null || true)
    REF=$($CRICTL inspect -o go-template --template '{{.status.imageRef}}' "$CID" 2>/dev/null || true)
    if [ "$STATE" != "CONTAINER_EXITED" ]; then
        echo "  -> FAIL: container $CID is in state '${STATE:-unknown}', not CONTAINER_EXITED"
        exit 1
    fi
    if [ "$REF" != "sha256:$WANT" ]; then
        echo "  -> FAIL: container $CID uses image '$REF', expected sha256:$WANT"
        exit 1
    fi
done
echo "  -> OK"

echo "[precondition] checking the three images are known to the CRI under their recorded ids"
echo "[precondition] and that no container at all uses the 'unused' one..."
for pair in "active:$IMG_ACTIVE" "stopped:$IMG_STOPPED" "unused:$IMG_UNUSED"; do
    NAME=${pair%%:*}; ID=${pair##*:}
    REF="docker.io/library/$CASE_ID-$NAME:latest"
    GOT=$($CRICTL inspecti -o go-template --template '{{.status.id}}' "$REF" 2>/dev/null || true)
    if [ "$GOT" != "sha256:$ID" ]; then
        echo "  -> FAIL: the CRI reports '${GOT:-no such image}' for $REF, expected sha256:$ID"
        exit 1
    fi
done
for c in $($CRICTL ps -a -q 2>/dev/null); do
    REF=$($CRICTL inspect -o go-template --template '{{.status.imageRef}}' "$c" 2>/dev/null || true)
    if [ "$REF" = "sha256:$IMG_UNUSED" ]; then
        echo "  -> FAIL: container $c uses the image that is supposed to be unused"
        exit 1
    fi
done
echo "  -> OK"

echo "[precondition] all checks passed."
