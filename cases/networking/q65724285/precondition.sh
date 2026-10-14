#!/bin/bash
set -e

CASE_ID="bench65724285"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ETC="/etc/$CASE_ID"
HOST="registry.$CASE_ID.test"
UNIT="$CASE_ID-containerd.service"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them and the lab is as its record says (binaries, unit, configuration, images, the registry process)..."
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
sudo python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[precondition] the service runs the lab's containerd 2.0.0 from its own configuration and socket..."
[ "$(sudo systemctl is-active "$UNIT")" = active ] || fail "$UNIT is not active"
sudo test -S "/run/$CASE_ID/containerd.sock" || fail "no CRI socket"
sudo "/var/lib/$CASE_ID/bin/containerd" --version | head -1
echo "  -> OK"

echo "[precondition] nothing of the solution exists yet: no hosts directory for ctr, the mirror endpoint of the CRI is https, no config_path..."
[ ! -e "$ETC/certs.d" ] || fail "$ETC/certs.d exists already"
! grep -q 'config_path = "[^"]' "$ETC/config.toml" || fail "the configuration has a config_path already"
grep -q "https://$HOST:5000" "$ETC/config.toml" || fail "the mirror endpoint of the configuration is not https://$HOST:5000"
echo "  -> OK"

echo "[precondition] the symptom and the controls: the registry is plain HTTP on port 5000, ctr --plain-http pulls the image, the exact ctr command of the check and the CRI pull both fail with 'server gave HTTP response to HTTPS client'..."
sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" || fail "see above"
