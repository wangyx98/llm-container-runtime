#!/bin/bash
set -e

CASE_ID="bench72528378"
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

echo "[precondition] nothing of the solution exists yet: no config_path, no hosts.toml, the registry keys of the configuration carry the port..."
! grep -q 'config_path = "[^"]' "$ETC/config.toml" || fail "the configuration has a config_path already"
grep -q "registry.mirrors.\"$HOST:80\"" "$ETC/config.toml" || fail "the configuration has no mirror for $HOST:80"
[ -z "$(sudo find /etc /var/lib/$CASE_ID /root -name hosts.toml 2>/dev/null | xargs -r sudo grep -l "$CASE_ID" 2>/dev/null)" ] || fail "a hosts.toml names the registry already"
echo "  -> OK"

echo "[precondition] the symptom and the controls: the registry is plain HTTP on port 80 (nothing on 443), ctr --plain-http pulls the reference, the CRI pull fails with 'dial tcp IP:443: connect: connection refused'..."
sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" || fail "see above"
