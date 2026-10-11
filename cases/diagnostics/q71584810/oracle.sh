#!/bin/bash
set -e

CASE_ID="bench71584810"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd.sock"
UNIT="$CASE_ID-containerd.service"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" || fail "see above"; }
keep() { python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (units, helpers), and the solution's script exists..."
[ "$(systemctl is-active "$UNIT" 2>/dev/null)" = active ] || fail "the unit $UNIT is not active"
(cd "$STATE_DIR" && sha256sum patch_config.py lab.py verify.py registry.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/export-pull-log.sh" ] || fail "there is no $WORK_DIR/export-pull-log.sh"
keep
echo "  -> OK"

echo "[oracle] the window of the pull that failed (its cursors in $WORK_DIR): the lines of the daemon in it, none of the registry or of the application, none of the pulls before and after..."
verify visible
keep
echo "[oracle] a new pull, made now with another image (and others before and after it), registry and application again logging the same words; the script cannot know it..."
python3 "$STATE_DIR/lab.py" window "$T_SOCK" "$WORK_DIR" hidden || fail "the lab could not make the new pull"
verify hidden
keep
echo "  -> OK: reading the journal changed nothing (no unit restarted, no line lost)"

echo "[oracle] ALL CHECKS PASSED: for the old and the new pull the script writes exactly the messages the containerd unit logged between the two cursors, in order, without the lines of the registry and the application that look the same and without the other pulls, and the journal and the units are untouched."
