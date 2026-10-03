#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: whatever the solution did to /etc/crictl.yaml, grade
# against containerd itself
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench71218538"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
ACTIVE_REF="docker.io/library/$CASE_ID-active:latest"
STOPPED_REF="docker.io/library/$CASE_ID-stopped:latest"
UNUSED_REF="docker.io/library/$CASE_ID-unused:latest"

st() { cat "$STATE_DIR/$1" 2>/dev/null || true; }

echo "[oracle] check 0: containerd must be up and answering on the CRI..."
for _ in $(seq 1 30); do
    sudo systemctl is-active --quiet containerd && $CRICTL info >/dev/null 2>&1 && break
    sleep 0.5
done
sudo systemctl is-active --quiet containerd || { echo "  -> FAIL: containerd is not active"; exit 1; }
sudo ctr version >/dev/null 2>&1 || { echo "  -> FAIL: ctr cannot talk to containerd"; exit 1; }
$CRICTL info >/dev/null 2>&1 || { echo "  -> FAIL: crictl cannot talk to containerd"; exit 1; }
POD_ID=$(st pod_id); ACTIVE_ID=$(st container_active); JOB_ID=$(st container_job); OLD_ID=$(st container_old)
IMG_ACTIVE=$(st image_id_active); IMG_STOPPED=$(st image_id_stopped); IMG_UNUSED=$(st image_id_unused)
PID_REC=$(st pid); START_REC=$(st starttime); NONCE_REC=$(st nonce)
for v in "$POD_ID" "$ACTIVE_ID" "$JOB_ID" "$OLD_ID" "$IMG_ACTIVE" "$IMG_STOPPED" "$IMG_UNUSED" \
         "$PID_REC" "$START_REC" "$NONCE_REC"; do
    [ -n "$v" ] || { echo "  -> FAIL: setup's recorded ids / pid / nonce are missing"; exit 1; }
done
echo "  -> OK"

echo "[oracle] check 1: the stopped containers must be gone (the two setup left, and no"
echo "[oracle]          other exited container of this case)..."
for pair in "bench71218538-job:$JOB_ID" "bench71218538-old:$OLD_ID"; do
    NAME=${pair%%:*}; CID=${pair##*:}
    STATE=$($CRICTL inspect -o go-template --template '{{.status.state}}' "$CID" 2>/dev/null || true)
    if [ -n "$STATE" ]; then
        echo "  -> FAIL: the stopped container $NAME ($CID) still exists (state $STATE)"
        exit 1
    fi
done
LEFT=$($CRICTL ps -a -q --name "$CASE_ID" --state exited 2>/dev/null || true)
if [ -n "$LEFT" ]; then
    echo "  -> FAIL: exited container(s) of this case are still there: $(echo $LEFT | tr '\n' ' ')"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: the unused images must be gone: the one no container ever used and"
echo "[oracle]          the one only a stopped container used. Gone means the CRI no longer"
echo "[oracle]          knows them (not even as a nameless '<none>' image)..."
for pair in "$UNUSED_REF:$IMG_UNUSED" "$STOPPED_REF:$IMG_STOPPED"; do
    REF=${pair%:*}; ID=${pair##*:}
    if sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -qxF "$REF"; then
        echo "  -> FAIL: $REF is still listed in namespace k8s.io"
        exit 1
    fi
    if $CRICTL inspecti "sha256:$ID" >/dev/null 2>&1 || $CRICTL inspecti "$REF" >/dev/null 2>&1; then
        echo "  -> FAIL: the CRI still knows the image of $REF (sha256:$ID), e.g. as '<none>' in 'crictl images': only its name was removed"
        exit 1
    fi
    if sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -qxF "sha256:$ID"; then
        echo "  -> FAIL: the record sha256:$ID of $REF is still in namespace k8s.io"
        exit 1
    fi
done
echo "  -> OK"

echo "[oracle] check 3: the workload must be untouched: same container, still running, same"
echo "[oracle]          process, heartbeat advancing, pod still ready..."
STATE=$($CRICTL inspect -o go-template --template '{{.status.state}}' "$ACTIVE_ID" 2>/dev/null || true)
if [ -z "$STATE" ]; then
    echo "  -> FAIL: the workload container $ACTIVE_ID does not exist any more (it was removed)"
    exit 1
fi
if [ "$STATE" != "CONTAINER_RUNNING" ]; then
    echo "  -> FAIL: the workload container $ACTIVE_ID is not running (state $STATE): it was stopped"
    exit 1
fi
PID=$($CRICTL inspect -o go-template --template '{{.info.pid}}' "$ACTIVE_ID" 2>/dev/null || true)
START=$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" 2>/dev/null | awk '{print $20}')
if [ "$PID" != "$PID_REC" ] || [ "$START" != "$START_REC" ]; then
    echo "  -> FAIL: the workload process changed (host pid $PID_REC/start $START_REC before, $PID/${START:-gone} now): it was restarted"
    exit 1
fi
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
POD_STATE=$($CRICTL inspectp -o go-template --template '{{.status.state}}' "$POD_ID" 2>/dev/null || true)
if [ "$POD_STATE" != "SANDBOX_READY" ]; then
    echo "  -> FAIL: the pod sandbox $POD_ID is '${POD_STATE:-gone}', not SANDBOX_READY"
    exit 1
fi
echo "  -> OK (host pid $PID, counter $C1 -> $C2)"

echo "[oracle] check 4: the image the workload runs must still be there, by name and by id..."
if ! sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -qxF "$ACTIVE_REF"; then
    echo "  -> FAIL: $ACTIVE_REF is not listed in namespace k8s.io any more: the image of the running workload was removed"
    exit 1
fi
GOT=$($CRICTL inspecti -o go-template --template '{{.status.id}}' "$ACTIVE_REF" 2>/dev/null || true)
if [ "$GOT" != "sha256:$IMG_ACTIVE" ]; then
    echo "  -> FAIL: the CRI reports '${GOT:-no such image}' for $ACTIVE_REF, expected sha256:$IMG_ACTIVE"
    exit 1
fi
echo "  -> OK ($GOT)"

echo "[oracle] all checks passed."
