#!/bin/bash
set -e

CASE_ID="bench73176776"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the lab is as setup left it: the node's containerd runs and the helpers are unchanged..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/logs.sh" ] || fail "there is no $WORK_DIR/logs.sh (the script that prints the log of the container whose id it is given)"
echo "  -> OK"

echo "[oracle] the target container: what logs.sh prints for its id is its stdout on stdout and its stderr on stderr, byte for byte, in order..."
python3 "$STATE_DIR/verify.py" "$WORK_DIR" target || fail "see above"
echo "[oracle] the neighbor container (another id, one pod, other markers): the same, and none of the target's messages in it, nor the reverse..."
python3 "$STATE_DIR/verify.py" "$WORK_DIR" neighbor || fail "see above"

echo "[oracle] the real logs and the containers are still there (reading is not consuming)..."
python3 "$STATE_DIR/lab.py" keep "$T_SOCK" "$WORK_DIR" || fail "see above"
echo "  -> OK: the pod and both containers run, both CRI log files still begin with the records they had"

echo "[oracle] new messages: both containers log more; logs.sh must show them, appended in order, for each container..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" target || fail "the lab could not make the target log more"
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" neighbor || fail "the lab could not make the neighbor log more"
python3 "$STATE_DIR/verify.py" "$WORK_DIR" target || fail "after new messages: see above"
python3 "$STATE_DIR/verify.py" "$WORK_DIR" neighbor || fail "after new messages: see above"
python3 "$STATE_DIR/lab.py" keep "$T_SOCK" "$WORK_DIR" || fail "after new messages: see above"

echo "[oracle] ALL CHECKS PASSED: logs.sh prints the stdout and the stderr of the container it is given, byte for byte and in order, nothing of the neighbor, the new messages too; the logs and the containers are kept."
