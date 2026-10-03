#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: whatever the solution did to /etc/crictl.yaml, grade
# against containerd itself
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CASE_ID="bench65393959"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"

st() { cat "$STATE_DIR/$1" 2>/dev/null || true; }

echo "[oracle] check 0: containerd must be up and answering on the CRI..."
for _ in $(seq 1 30); do
    sudo systemctl is-active --quiet containerd && $CRICTL info >/dev/null 2>&1 && break
    sleep 0.5
done
sudo systemctl is-active --quiet containerd || { echo "  -> FAIL: containerd is not active"; exit 1; }
$CRICTL info >/dev/null 2>&1 || { echo "  -> FAIL: crictl cannot talk to containerd"; exit 1; }
CONTAINER_ID=$(st container_id); PID_REC=$(st pid); PIDNS_REC=$(st pidns); TOKEN=$(st token)
OWNER_UID=$(st uid); OWNER_GID=$(st gid); OWNER_NAME=$(st name)
for v in "$CONTAINER_ID" "$PID_REC" "$PIDNS_REC" "$TOKEN" "$OWNER_UID" "$OWNER_GID" "$OWNER_NAME"; do
    [ -n "$v" ] || { echo "  -> FAIL: setup's recorded ids / token are missing"; exit 1; }
done
echo "  -> OK"

echo "[oracle] check 1: the container must be the one setup started, still running as root:"
echo "[oracle]          the user has to be switched for the command, not for the container..."
STATE=$($CRICTL inspect -o go-template --template '{{.status.state}}' "$CONTAINER_ID" 2>/dev/null || true)
if [ -z "$STATE" ]; then
    echo "  -> FAIL: container $CONTAINER_ID does not exist any more (it was removed or replaced)"
    exit 1
fi
if [ "$STATE" != "CONTAINER_RUNNING" ]; then
    echo "  -> FAIL: container $CONTAINER_ID is not running (state $STATE)"
    exit 1
fi
PID=$($CRICTL inspect -o go-template --template '{{.info.pid}}' "$CONTAINER_ID" 2>/dev/null || true)
RUID=$(sudo awk '$1 == "Uid:" {print $2}' "/proc/$PID/status" 2>/dev/null || true)
if [ "$PID" != "$PID_REC" ] || [ "$RUID" != "0" ]; then
    echo "  -> FAIL: the container's main process changed (host pid $PID_REC before, ${PID:-gone} now, uid ${RUID:-unknown}): it was restarted or run as another user"
    exit 1
fi
echo "  -> OK (host pid $PID, uid $RUID)"

echo "[oracle] check 2: the script must have run and written $DATA_DIR/done..."
if ! sudo test -f "$DATA_DIR/done"; then
    echo "  -> FAIL: $DATA_DIR/done does not exist: /usr/bin/rotate never ran to completion in the container"
    exit 1
fi
DONE=$(sudo cat "$DATA_DIR/done")
field() { echo "$DONE" | sed -n "s/^$1=//p" | head -1; }
OWN=$(sudo stat -c '%u:%g' "$DATA_DIR/done")
echo "  -> OK (file owner $OWN)"

echo "[oracle] check 3: it must have run as the owner of the data ($OWNER_NAME, uid $OWNER_UID),"
echo "[oracle]          not as root and not as another user..."
if [ "$(field uid)" != "$OWNER_UID" ] || [ "$(field user)" != "$OWNER_NAME" ]; then
    echo "  -> FAIL: the script ran as uid '$(field uid)' (user '$(field user)'), expected uid $OWNER_UID ($OWNER_NAME)"
    exit 1
fi
if [ "${OWN%%:*}" != "$OWNER_UID" ]; then
    echo "  -> FAIL: $DATA_DIR/done is owned by uid ${OWN%%:*}, expected $OWNER_UID"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 4: and with the owner's group (gid $OWNER_GID), not root's..."
if [ "$(field gid)" != "$OWNER_GID" ]; then
    echo "  -> FAIL: the script ran with gid '$(field gid)', expected $OWNER_GID (groups: '$(field groups)')"
    exit 1
fi
if [ "${OWN##*:}" != "$OWNER_GID" ]; then
    echo "  -> FAIL: $DATA_DIR/done has group ${OWN##*:}, expected $OWNER_GID"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 5: the result must come from the script itself (its per-run token)..."
if [ "$(field token)" != "$TOKEN" ]; then
    echo "  -> FAIL: the token in $DATA_DIR/done is '$(field token)': the file was not written by /usr/bin/rotate from this image"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 6: it must have run inside the container that is running, not in another"
echo "[oracle]          one made from the same image (same pid namespace as its main process)..."
NOW_NS=$(sudo readlink "/proc/$PID/ns/pid" 2>/dev/null || true)
if [ "$(field pidns)" != "$PIDNS_REC" ] || [ "$NOW_NS" != "$PIDNS_REC" ]; then
    echo "  -> FAIL: the script ran in pid namespace '$(field pidns)', the container's is '$PIDNS_REC': it ran in a different container"
    exit 1
fi
echo "  -> OK ($PIDNS_REC)"

echo "[oracle] all checks passed."
