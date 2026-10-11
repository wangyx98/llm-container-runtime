#!/bin/bash
set -e

CASE_ID="bench71584810"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd.sock"
UNITS=("$CASE_ID-containerd.service" "$CASE_ID-registry.service" "$CASE_ID-app.service")

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] checking systemd is the init of this machine, the three units run and the helpers are as setup copied them..."
[ -d /run/systemd/system ] || fail "the machine is not booted with systemd"
for u in "${UNITS[@]}"; do
    [ "$(systemctl is-active "$u" 2>/dev/null)" = active ] || fail "the unit $u is not active"
done
(cd "$STATE_DIR" && sha256sum patch_config.py lab.py verify.py registry.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}'), ${UNITS[0]} active"

echo "[precondition] the cursor files hold two different journal cursors..."
for f in cursor.start cursor.end; do
    [[ "$(cat "$WORK_DIR/$f" 2>/dev/null)" =~ ^s=[0-9a-f]+\;i=[0-9a-f]+\;b=[0-9a-f]+\;m=[0-9a-f]+\;t=[0-9a-f]+\;x=[0-9a-f]+$ ]] || fail "$WORK_DIR/$f does not hold a journal cursor"
done
[ "$(cat "$WORK_DIR/cursor.start")" != "$(cat "$WORK_DIR/cursor.end")" ] || fail "the two cursors are the same"
echo "  -> OK"

echo "[precondition] the journal holds the pull that failed, between the cursors, as the daemon's lines; the registry and an application logged the same words; other pulls came before and after..."
python3 - "$STATE_DIR/state.json" <<'PYEOF' || fail "the journal is not what the case is built on"
import json
import sys

st = json.load(open(sys.argv[1]))
w = st["windows"]["visible"]
ref = w["ref"]
assert w["status"].startswith("429"), "the pull that matters is not the throttled one"
assert any('PullImage \\"%s\\" failed' % ref in m and "429 Too Many Requests" in m for m in w["expected"]), "no error line of the daemon in the window"
assert len(w["expected"]) >= 3 and any("stop pulling image" in m and ref in m for m in w["expected"]), "the window does not hold the daemon's lines about the pull to the end"
assert any(m.startswith("registry: ") for m in w["others"]), "the registry logged nothing in the window"
assert sum(1 for m in w["others"] if m.startswith("time=")) >= 2, "the application logged nothing like the daemon in the window"
assert not set(w["expected"]) & set(w["others"]), "a line of the daemon is also a line of another unit"
assert len(w["outside"]) >= 2 and not set(w["outside"]) & set(w["expected"]), "no pulls before and after the window"
print("  -> %d lines of the daemon in the window; the registry and the application logged %d lines with the same words (some of them in the window); the daemon logged %d other lines (about the pulls before and after)" % (len(w["expected"]), len(w["others"]), len(w["outside"])))
PYEOF
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[precondition] the problem: the log of the daemon is not a file under /var/log, and there is no export-pull-log.sh yet..."
[ ! -e "$WORK_DIR/export-pull-log.sh" ] || fail "$WORK_DIR/export-pull-log.sh exists already"
[ ! -e "/var/log/containerd.log" ] && [ ! -e "/var/log/containerd/containerd.log" ] || echo "  -> (the host has a containerd log file of its own; it is not this node's)"
sudo journalctl -u "${UNITS[0]}" -n 1 --no-pager -o cat 2>/dev/null | grep -q . || fail "the journal has no line of the unit"
echo "  -> OK: the unit's lines are in the journal only"

echo "[precondition] ALL CHECKS PASSED: a containerd unit whose journal holds a failed pull between two saved cursors, with a registry and an application logging the same words, and no export-pull-log.sh yet."
