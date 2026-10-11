#!/bin/bash
set -e

CASE_ID="bench48616250"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DSOCK="$RUN_BASE/docker.sock"
CSOCK="$RUN_BASE/containerd/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" || fail "see above"; }   # runs the script, checks the node is unchanged, compares
keep() { python3 "$STATE_DIR/lab.py" check "$DSOCK" "$CSOCK" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, Docker, helpers), and the solution's script exists..."
for f in containerd dockerd; do
    P=$(sudo cat "$RUN_BASE/$f.pid" 2>/dev/null || true)
    [ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = "$f" ] || fail "the $f of the case is not running"
done
(cd "$STATE_DIR" && sha256sum app.c mkimg.py patch_config.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/list-containers.sh" ] || fail "there is no $WORK_DIR/list-containers.sh"
keep
echo "  -> OK"

echo "[oracle] what each API lists (Docker, the CRI with its pods, ctr in every namespace), with the socket and the containerd namespace of each..."
verify first
echo "[oracle] the node changes (a container started and one removed in Docker; one started and one removed in the pod); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$DSOCK" "$CSOCK" "$WORK_DIR" >/dev/null || fail "the lab could not change the node"
verify second
keep
echo "  -> OK: reading the node changed nothing (no container created, started, stopped, removed, pruned or moved)"

echo "[oracle] ALL CHECKS PASSED: for the old and the new state of the node the script lists exactly the containers of Docker, of the CRI (containers and sandboxes) and of every containerd namespace, with the socket and the containerd namespace of each, and changes nothing."
