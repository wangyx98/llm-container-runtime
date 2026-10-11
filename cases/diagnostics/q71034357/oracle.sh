#!/bin/bash
set -e

CASE_ID="bench71034357"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" "$2" || fail "see above"; }
keep() { python3 "$STATE_DIR/lab.py" keep "$T_SOCK" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, helpers, containers and logs untouched), and the solution's script exists..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py reopen.py app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
keep
[ -s "$WORK_DIR/stopped-logs.sh" ] || fail "there is no $WORK_DIR/stopped-logs.sh"
echo "  -> OK"

echo "[oracle] job attempt 0, stopped: its whole log (three files, both streams, from its first message), nothing of attempt 1, its exit code and reason..."
verify job 0
keep
echo "  -> OK: the logs and the containers are as they were (reading is not consuming)"

echo "[oracle] another container stops (job attempt 1 logs four more messages and exits with 0); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" >/dev/null || fail "the lab could not stop job attempt 1"
echo "[oracle] job attempt 1, now stopped: its log, nothing of attempt 0, exit code 0; and attempt 0 again (the same answer)..."
verify job 1
verify job 0
keep
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED: for each stopped attempt the script writes the whole log of that attempt (every rotated file, the compressed one too, partial records joined), its exit code and reason, nothing of the other attempt, and changes nothing on the node."
