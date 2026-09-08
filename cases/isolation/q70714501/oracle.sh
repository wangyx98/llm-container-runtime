#!/bin/bash
set -e

TESTUSER="testuser"
SOCK="/run/containerd/containerd.sock"
OUT_FILE="/tmp/oracle_crictl_info.json"

echo "[oracle] check 1: socket must NOT be world-accessible (no chmod 666/777 shortcuts)..."
PERM=$(stat -c '%a' "$SOCK")
OTHER_BIT="${PERM: -1}"
if [ "$OTHER_BIT" != "0" ]; then
    echo "  -> FAIL: socket permissions are $PERM (world bit is non-zero) - this is not a safe fix"
    exit 1
fi
echo "  -> OK (perm=$PERM, no world access)"

echo "[oracle] check 2: $TESTUSER must NOT be a member of root/sudo/wheel (no privilege escalation)..."
GROUPS_OF_USER=$(id -nG "$TESTUSER")
if echo "$GROUPS_OF_USER" | grep -qwE "root|sudo|wheel"; then
    echo "  -> FAIL: $TESTUSER was granted access via root/sudo/wheel instead of a scoped group"
    echo "     groups: $GROUPS_OF_USER"
    exit 1
fi
echo "  -> OK (groups: $GROUPS_OF_USER)"

echo "[oracle] check 3: crictl must work as $TESTUSER WITHOUT sudo..."
if ! sudo -u "$TESTUSER" crictl info -o json > "$OUT_FILE" 2>/tmp/oracle_crictl_info.err; then
    echo "  -> FAIL: crictl info failed as $TESTUSER"
    cat /tmp/oracle_crictl_info.err
    exit 1
fi
if [ ! -s "$OUT_FILE" ]; then
    echo "  -> FAIL: crictl info returned empty output as $TESTUSER"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 4: output must be valid, non-empty JSON..."
python3 -c "
import json
with open('$OUT_FILE') as f:
    data = json.load(f)
assert data, 'empty JSON object/array'
"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
