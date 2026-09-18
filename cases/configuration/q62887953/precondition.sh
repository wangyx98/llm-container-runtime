#!/bin/bash
set -e

CONTAINER="bench62887953"
BUNDLE_DIR="/tmp/bench62887953/bundle"

echo "[precondition] checking bundle/rootfs artifacts exist..."
test -f "$BUNDLE_DIR/config.json"
test -f "$BUNDLE_DIR/rootfs/victim"
test -f "$BUNDLE_DIR/rootfs/preload.so"
echo "  -> OK"

echo "[precondition] confirming the CURRENT (broken) config.json fails to run..."
sudo runc delete -f "bench62887953-precheck" 2>/dev/null || true
if sudo runc run --bundle "$BUNDLE_DIR" "bench62887953-precheck" > /tmp/bench62887953_pre_out.txt 2>&1; then
    echo "[precondition] FAIL: container ran successfully before any fix was applied"
    cat /tmp/bench62887953_pre_out.txt
    exit 1
fi
echo "  -> run failed as expected:"
sed 's/^/     /' /tmp/bench62887953_pre_out.txt

sudo runc delete -f "bench62887953-precheck" 2>/dev/null || true
rm -f /tmp/bench62887953_pre_out.txt

echo "[precondition] PASS - LD_PRELOAD smashed into 'args' does not work, matching"
echo "[precondition]        the SO scenario (no shell parses that string for you)."
