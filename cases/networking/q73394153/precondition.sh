#!/bin/bash
set -e

CASE_ID="bench73394153"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup left them; the registry, the proxy and k3s run..."
sudo test -s "$STATE_DIR/truth.json" || fail "setup did not leave its record"
sudo bash -c 'cd "$1" && sha256sum app.c mkoci.py registry.py proxy.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper changed"
sudo "/var/lib/$CASE_ID/bin/k3sctl" status >/dev/null || fail "k3s is not running"
echo "  -> OK"

echo "[precondition] the proxy wants credentials (407 without and with a wrong password) and tunnels with the right ones, the registry resets a direct connection; the VM's files and k3s carry no proxy;"
echo "               nerdctl and the Pod cannot pull (DNS); controls: nerdctl given the proxy in its own environment pulls, a wrong password gets 407; a Pod from the local image runs and kubectl logs works..."
sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" || fail "see above"

echo "[precondition] ALL CHECKS PASSED: a Rancher Desktop VM stand-in whose nerdctl and k3s cannot pull from the registry (no DNS, no proxy settings); the proxy needs credentials; the cluster's own traffic works."
