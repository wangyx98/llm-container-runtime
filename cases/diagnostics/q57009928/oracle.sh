#!/bin/bash
set -e

CASE_ID="bench57009928"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DSOCK="$RUN_BASE/docker.sock"
R=$(cat "$STATE_DIR/rand" 2>/dev/null || true)
EXEC="$RUN_BASE/exec-$R"
CSOCK="$RUN_BASE/ctd-$R/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" || fail "see above"; }   # runs the script, checks the node is unchanged, compares
keep() { python3 "$STATE_DIR/lab.py" check "$DSOCK" "$CSOCK" "$EXEC" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, Docker, helpers), and the solution's script exists..."
[ -n "$R" ] || fail "setup did not record the random names"
for f in containerd dockerd; do
    P=$(sudo cat "$RUN_BASE/$f.pid" 2>/dev/null || true)
    [ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = "$f" ] || fail "the $f of the case is not running"
done
(cd "$STATE_DIR" && sha256sum app.c mkimg.py patch_config.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/find-runtime.sh" ] || fail "there is no $WORK_DIR/find-runtime.sh"
keep
echo "  -> OK"

echo "[oracle] the runtime root of Docker's containers with their IDs and PIDs, the containerd socket and namespace, the images in containerd, and runc has no images..."
verify first
echo "[oracle] the node changes (a second image, a new container, one container removed; the first container keeps running); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$DSOCK" "$CSOCK" "$EXEC" "$WORK_DIR" >/dev/null || fail "the lab could not change the node"
verify second
keep
echo "  -> OK: reading the node changed nothing (no container started, stopped or restarted, no image loaded or removed)"

echo "[oracle] ALL CHECKS PASSED: for the old and the new state of the node the script finds Docker's runtime root, containerd socket and namespace, lists the containers with their real IDs and PIDs and the images of containerd, says that runc has none, and interrupts nothing."
