#!/bin/bash
set -e

CONTAINER="bench72392812"
WORK_DIR="/tmp/bench72392812"
LOG_DIR="$WORK_DIR/runsc-logs"
RUNSC_CONF="$WORK_DIR/runsc.toml"

echo "[precondition] checking container '$CONTAINER' does NOT exist yet..."
if sudo ctr containers ls | grep -q "$CONTAINER"; then
    echo "  -> FAIL: container already exists (did cleanup.sh run?)"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking runsc debug config is in place at $RUNSC_CONF ..."
test -f "$RUNSC_CONF"
grep -q 'debug-log' "$RUNSC_CONF"
echo "  -> OK"

echo "[precondition] checking log directory exists and is EMPTY (no debug logs generated yet)..."
test -d "$LOG_DIR"
if [ -n "$(find "$LOG_DIR" -mindepth 1 2>/dev/null)" ]; then
    echo "  -> FAIL: $LOG_DIR already has content, expected it empty."
    exit 1
fi
echo "  -> OK"

echo "[precondition] PASS - gVisor is configured for debug logging but no logs exist yet,"
echo "[precondition]        matching the reported bug (config present, no files generated)."
