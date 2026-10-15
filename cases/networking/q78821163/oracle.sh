#!/bin/bash
set -e

CASE_ID="bench78821163"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the helpers are as setup copied them, the lab is as setup made it..."
(cd "$STATE_DIR" && sha256sum app.c entrypoint.c probe.go mkdind.py mkoci.py dns.py registry.py netprobe.py lab.py verify.py patch_config.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
python3 "$STATE_DIR/lab.py" check "$WORK_DIR" 2>&1 || fail "the lab is not as setup left it (see the line above)"
echo "  -> OK"

echo "[oracle] the program in $WORK_DIR/app builds and makes a NEW container in the pod's network namespace (not the host's); the Docker inside pulls a new image from private-repo.local through the lab's DNS server and registry, and runs it with a nonce..."
python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1 || fail "see above"
