#!/bin/bash
set -e

CASE_ID="bench72094271"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
UNIT="$CASE_ID-containerd.service"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them and the lab is as its record says (images, kernel.core_pattern, the service)..."
sudo bash -c 'cd "$1" && sha256sum probe.c pause.c mkimg.py patch_config.py lab.py verify.py baseline.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
sudo python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[precondition] the service $UNIT runs, its unit file has LimitCORE=infinity and no drop-in, and the configuration sets no rlimit (base_runtime_spec is empty)..."
[ "$(sudo systemctl is-active "$UNIT")" = active ] || fail "$UNIT is not active"
sudo grep -q '^LimitCORE=infinity' "/etc/systemd/system/$UNIT" || fail "the unit file has not LimitCORE=infinity"
[ ! -e "/etc/systemd/system/$UNIT.d" ] || fail "the unit has drop-ins already"
sudo grep -q "^ *base_runtime_spec = ''" "/etc/$CASE_ID/containerd.toml" || fail "base_runtime_spec is set in the configuration"
echo "  -> OK"

echo "[precondition] controls: a new container has core=unlimited (main process and exec), SIGABRT leaves a core file, a process that limits itself to 0 leaves none..."
OUT=$(sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" 2>&1) || { echo "$OUT" | tail -3; fail "see above"; }
echo "$OUT" | tail -3

echo "[precondition] PASS - the containers of the node have an unlimited core file size; the controls work."
