#!/bin/bash
set -e

TESTUSER="testuser"

echo "[precondition] checking that $TESTUSER currently CANNOT use crictl..."
if sudo -u "$TESTUSER" crictl info > /dev/null 2>&1; then
    echo "[precondition] FAIL: $TESTUSER can already run crictl info before any fix was applied"
    exit 1
fi
echo "[precondition] PASS - $TESTUSER is correctly denied access in the initial state."
