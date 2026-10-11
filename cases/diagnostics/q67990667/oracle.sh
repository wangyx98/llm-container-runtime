#!/bin/bash
set -e

CASE_ID="bench67990667"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" || fail "see above"; }   # runs the script, checks the node is unchanged, compares
keep() { python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, helpers), and the solution's script exists..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the containerd of the case is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py idle.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/inspect.sh" ] || fail "there is no $WORK_DIR/inspect.sh"
keep
echo "  -> OK"

echo "[oracle] the containers of the node: every namespace, the same ID in several of them, image, runtime, labels, env, mounts, and the state and PID of the task (none for a container that has no task)..."
verify first
echo "[oracle] the node changes (a task started, a process killed so that its task is stopped, a task removed, a container in a new namespace); the script cannot know it..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" >/dev/null || fail "the lab could not change the node"
verify second
keep
echo "  -> OK: reading the containers changed nothing (no container, label, task or namespace)"

echo "[oracle] ALL CHECKS PASSED: for the old and the new state of the node the script reports every container of every namespace with its record, its spec fields and the live state and PID of its task, and changes nothing."
