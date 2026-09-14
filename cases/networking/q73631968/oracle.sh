#!/bin/bash
set -e

CONTAINER="bench73631968"
BAD_PORT=18973
DUMMY_MARKER="DUMMY_SERVICE_bench73631968_DO_NOT_TOUCH"
CONTAINER_MARKER="CONTAINER_CONTENT_bench73631968"

echo "[oracle] check 0: the pre-existing host service on port $BAD_PORT must be untouched..."
curl -fsS --max-time 3 "http://127.0.0.1:$BAD_PORT/" | grep -q "$DUMMY_MARKER"
echo "  -> OK"

echo "[oracle] check 1: container '$CONTAINER' must exist and be running..."
sudo nerdctl ps | grep -q "$CONTAINER"
echo "  -> OK"

echo "[oracle] check 2: it must still be the same busybox-based container (not swapped)..."
sudo nerdctl inspect "$CONTAINER" 2>/dev/null | grep -qi "busybox"
echo "  -> OK"

echo "[oracle] check 3: its content must actually be reachable via SOME published host port..."
PORTS=$(sudo nerdctl port "$CONTAINER" 2>/dev/null | python3 -c "
import sys, re
ports = set()
for line in sys.stdin:
    m = re.search(r':(\d+)\s*\$', line.strip())
    if m:
        ports.add(m.group(1))
print(' '.join(sorted(ports)))
")

if [ -z "$PORTS" ]; then
    echo "  -> FAIL: 'nerdctl port $CONTAINER' returned no published ports"
    exit 1
fi

FOUND=0
for P in $PORTS; do
    RESPONSE=$(curl -fsS --max-time 3 "http://127.0.0.1:$P/" || true)
    if echo "$RESPONSE" | grep -q "$CONTAINER_MARKER"; then
        echo "  -> OK (reachable on host port $P)"
        FOUND=1
        break
    fi
done

if [ "$FOUND" -ne 1 ]; then
    echo "  -> FAIL: container content not reachable on any of its published ports: $PORTS"
    exit 1
fi

echo "[oracle] ALL CHECKS PASSED"
