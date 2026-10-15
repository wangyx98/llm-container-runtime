#!/bin/bash
set -e

CASE_ID="bench60208766"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] verifying the helpers are as setup copied them..."
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py proxy.py api.py alias.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"

echo "[oracle] restarting the service, then twice (the second time after another restart and an emptied store): a cold image pull through the proxy, two new Pods with the Calico network, the netns and the IPs, the nonce from one Pod to the other, the logs of the API and of the proxy, the Pods taken down..."
OUT=$(sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" 2>&1) && RC=0 || RC=$?
echo "$OUT" | tail -5
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: new Pods get their network from the real Calico plugin, which reaches the Kubernetes API directly, while the node's image pulls still go through the proxy, before and after a restart."
