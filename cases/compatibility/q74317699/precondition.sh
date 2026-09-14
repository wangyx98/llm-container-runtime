#!/bin/bash
set -e

CONTAINER="bench74317699"

echo "[precondition] checking container is in STOPPED state (matches the SO scenario)..."
STATUS=$(sudo runc list --format json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data:
    if c.get('id') == '$CONTAINER':
        print(c.get('status', ''))
        break
")

if [ "$STATUS" != "stopped" ]; then
    echo "  -> FAIL: expected status 'stopped', got '${STATUS:-<not found>}'"
    exit 1
fi

echo "[precondition] PASS - container '$CONTAINER' is stopped, matching runc's error"
echo "[precondition]        'cannot start a container that has stopped'."
