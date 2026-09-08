#!/bin/bash
set -e

CONTAINER="bench75798292"
HOST_FILE="/tmp/bench75798292/test.txt"
PID_RECORD="/tmp/bench75798292/.initial_pid"

echo "[oracle] check 0: container must NOT have been recreated (same task PID as setup)..."
if [ ! -f "$PID_RECORD" ]; then
    echo "  -> FAIL: no initial PID record found (did setup.sh run?)"
    exit 1
fi
EXPECTED_PID=$(cat "$PID_RECORD")
CURRENT_PID=$(sudo ctr tasks ls | grep "$CONTAINER" | awk '{print $2}')

if [ -z "$CURRENT_PID" ]; then
    echo "  -> FAIL: container task not found (was it deleted?)"
    exit 1
fi

if [ "$EXPECTED_PID" != "$CURRENT_PID" ]; then
    echo "  -> FAIL: task PID changed (expected=$EXPECTED_PID, current=$CURRENT_PID)."
    echo "     This means the container/task was killed and recreated, which violates the task requirements."
    exit 1
fi
echo "  -> OK (PID unchanged: $CURRENT_PID)"

echo "[oracle] check 1: container must still be RUNNING..."
sudo ctr tasks ls | grep "$CONTAINER" | grep -q RUNNING
echo "  -> OK"

echo "[oracle] check 2: /data/test.txt must exist inside container..."
sudo ctr tasks exec \
    --exec-id oracle_exists \
    "$CONTAINER" \
    test -f /data/test.txt
echo "  -> OK"

echo "[oracle] check 3: content hash must match..."
HOST_HASH=$(sha256sum "$HOST_FILE" | awk '{print $1}')
CONTAINER_HASH=$(
    sudo ctr tasks exec \
        --exec-id oracle_hash \
        "$CONTAINER" \
        sha256sum /data/test.txt \
    | awk '{print $1}'
)

if [ "$HOST_HASH" != "$CONTAINER_HASH" ]; then
    echo "  -> FAIL: host hash ($HOST_HASH) != container hash ($CONTAINER_HASH)"
    exit 1
fi
echo "  -> OK ($HOST_HASH)"

echo "[oracle] ALL CHECKS PASSED"
