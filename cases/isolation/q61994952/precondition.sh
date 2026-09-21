#!/bin/bash
set -e

WORK_DIR="/tmp/bench61994952"
RUNC_ROOT="$WORK_DIR/runc-root"
VERDICT_FILE="$WORK_DIR/verdict.json"
GROUND_TRUTH_FILE="$WORK_DIR/ground_truth.json"

C1="bench61994952-c1"
C2="bench61994952-c2"
C3="bench61994952-c3"
C4="bench61994952-c4"

echo "[precondition] checking runc is installed..."
command -v runc >/dev/null 2>&1

echo "[precondition] checking all 4 containers exist and are in 'created' state..."
for c in "$C1" "$C2" "$C3" "$C4"; do
    STATUS=$(sudo runc --root "$RUNC_ROOT" state "$c" 2>/dev/null | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('status', ''))
except Exception:
    print('')
")
    if [ "$STATUS" != "created" ]; then
        echo "  -> FAIL: container '$c' is not in 'created' state (got '${STATUS:-<missing>}')"
        exit 1
    fi
done
echo "  -> OK (all 4 present and 'created')"

echo "[precondition] checking the ground-truth file exists (setup ran)..."
sudo test -f "$GROUND_TRUTH_FILE"

echo "[precondition] checking no stale verdict.json exists yet..."
if [ -f "$VERDICT_FILE" ]; then
    echo "  -> FAIL: $VERDICT_FILE already exists before the solution ran"
    exit 1
fi

echo "[precondition] PASS - 4 runc containers are ready for inspection and"
echo "[precondition]        no verdict has been written yet."
