#!/bin/bash
set -e

POD_CONFIG="/tmp/bench61058619_pod.json"
CONTAINER_CONFIG="/tmp/bench61058619_container.json"
POD_ID=$(cat /tmp/bench61058619_podid.txt)

echo "[precondition] sanity check: pod sandbox itself must be Ready (unaffected by the bug)..."
sudo crictl pods --id "$POD_ID" --output json | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('items', [])
assert items, 'pod not found'
assert items[0]['state'] == 'SANDBOX_READY', f\"unexpected state: {items[0]['state']}\"
"
echo "  -> pod sandbox OK (as expected, the bug is at the container level)"

echo "[precondition] checking that CONTAINER creation currently FAILS (broken seccomp profile)..."
if sudo crictl create "$POD_ID" "$CONTAINER_CONFIG" "$POD_CONFIG" > /tmp/precheck_ctrid.txt 2>/tmp/precheck_err.txt; then
    echo "[precondition] FAIL: container was created successfully before any fix was applied"
    cat /tmp/precheck_ctrid.txt
    exit 1
fi

echo "[precondition] PASS - container creation correctly fails in the broken initial state."
echo "  (error was: $(tail -1 /tmp/precheck_err.txt))"
