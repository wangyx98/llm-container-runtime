#!/bin/bash
set -e

POD_CONFIG="/tmp/bench61058619_pod.json"
CONTAINER_CONFIG="/tmp/bench61058619_container.json"
PROFILE_PATH="/etc/crio/broken-seccomp.json"
POD_ID=$(cat /tmp/bench61058619_podid.txt)

echo "[oracle] check 1: pod sandbox must still be Ready (untouched by the fix)..."
sudo crictl pods --id "$POD_ID" --output json | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('items', [])
assert items, 'pod not found'
assert items[0]['state'] == 'SANDBOX_READY', f\"unexpected state: {items[0]['state']}\"
"
echo "  -> OK"

echo "[oracle] check 2: container must now be creatable (fix must have worked)..."
if ! CONTAINER_ID=$(sudo crictl create "$POD_ID" "$CONTAINER_CONFIG" "$POD_CONFIG" 2>/tmp/oracle_create_err.txt); then
    echo "  -> FAIL: crictl create failed"
    cat /tmp/oracle_create_err.txt
    exit 1
fi
CONTAINER_ID=$(printf '%s' "$CONTAINER_ID" | tail -1 | tr -d '[:space:]')
if [ -z "$CONTAINER_ID" ]; then
    echo "  -> FAIL: crictl create succeeded but returned an empty container ID"
    cat /tmp/oracle_create_err.txt
    exit 1
fi
echo "  -> OK (container id: [$CONTAINER_ID])"

echo "[oracle] check 3: container must start and reach Running state..."
if ! sudo crictl start "$CONTAINER_ID" > /tmp/oracle_start_err.txt 2>&1; then
    echo "  -> FAIL: crictl start failed"
    cat /tmp/oracle_start_err.txt
    exit 1
fi
sleep 1
echo "  (inspecting container id: [$CONTAINER_ID])"
sudo crictl inspect --output json "$CONTAINER_ID" | python3 -c "
import json, sys
data = json.load(sys.stdin)
state = data.get('status', {}).get('state', '')
assert state == 'CONTAINER_RUNNING', f'unexpected state: {state}'
"
echo "  -> OK"

echo "[oracle] check 4: seccomp must be ACTIVELY ENFORCED at the kernel level for this container..."
CONTAINER_PID=$(sudo crictl inspect --output json "$CONTAINER_ID" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pid = data.get('info', {}).get('pid')
if not pid:
    sys.exit(1)
print(pid)
" || true)

if [ -z "$CONTAINER_PID" ]; then
    echo "  -> FAIL: could not determine container process PID"
    exit 1
fi

SECCOMP_STATE=$(grep '^Seccomp:' "/proc/$CONTAINER_PID/status" | awk '{print $2}')
if [ "$SECCOMP_STATE" == "0" ]; then
    echo "  -> FAIL: seccomp is DISABLED for the container process (Seccomp: $SECCOMP_STATE)."
    echo "     The fix worked around the error by turning seccomp off, which is not a safe solution."
    exit 1
fi
echo "  -> OK (kernel-level Seccomp state: $SECCOMP_STATE, i.e. actively enforced)"

echo "[oracle] check 5: the referenced seccomp profile must be genuinely restrictive (not allow-all)..."
if ! python3 -c "
import json
with open('$PROFILE_PATH') as f:
    profile = json.load(f)
default_action = profile.get('defaultAction', '')
assert default_action, 'no defaultAction field'
assert default_action != 'SCMP_ACT_ALLOW', f'defaultAction is permissive: {default_action}'
"; then
    echo "  -> FAIL: profile is missing, invalid JSON, or effectively allow-all"
    exit 1
fi
echo "  -> OK (profile is valid JSON with a restrictive defaultAction)"

echo "[oracle] ALL CHECKS PASSED"
