#!/bin/bash
set -e

CASE_ID="bench71705752"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" "$2" "$3" || fail "see above"; }
keep() { python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, helpers), and the solution's script exists..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the containerd of the case is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/inspect-node.sh" ] || fail "there is no $WORK_DIR/inspect-node.sh"
keep
echo "  -> OK"

echo "[oracle] the container rabbitmq of prod/rabbitmq-0 (user 1001; staging/rabbitmq-0 has a container of the same name): all containers, all images, its token and its user..."
verify prod rabbitmq-0 rabbitmq
keep
echo "[oracle] the container rabbitmq of staging/rabbitmq-0 (user 1002, another token)..."
verify staging rabbitmq-0 rabbitmq
keep
echo "  -> OK: the node is unchanged by reading it"

echo "[oracle] the node changes (two new pods, a new image, a finished job and an image removed); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" >/dev/null || fail "the lab could not change the node"
echo "[oracle] the container rabbitmq of qa/rabbitmq-0 (it runs as root, user 0: the identity is the container's, not an assumption) and of dev/rabbitmq-0 (user 1001)..."
verify qa rabbitmq-0 rabbitmq
keep
verify dev rabbitmq-0 rabbitmq
keep
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED: for the old and the new state of the node the script lists all its containers (exited ones too, no pod sandboxes) and all its images (as repository:tag), reads the token of the right container of several of the same name from inside it, under the user that container runs as, and changes nothing on the node."
