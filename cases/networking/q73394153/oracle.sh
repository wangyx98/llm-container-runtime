#!/bin/bash
set -e

CASE_ID="bench73394153"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the helpers are as setup left them..."
sudo test -s "$STATE_DIR/truth.json" || fail "the record of setup is gone"
sudo bash -c 'cd "$1" && sha256sum app.c mkoci.py registry.py proxy.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
echo "  -> OK"

echo "[oracle] the lab, the proxy's rules, the restart of Rancher Desktop, then nerdctl and k3s each pull a NEW image from an empty cache through the corporate proxy and run it (this takes a few minutes)..."
sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" || fail "see above"

echo "[oracle] ALL CHECKS PASSED: after the restart of Rancher Desktop both nerdctl and k3s pull new images through the credentialed proxy and run them, the cluster still works, and the password is in no log or command line."
