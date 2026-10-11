#!/bin/bash
set -e

CASE_ID="bench64071782"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }
verify() { python3 "$STATE_DIR/verify.py" "$WORK_DIR" "$1" || fail "see above"; }   # runs the script, compares with what the lab knows
keep() { python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (helpers, the two containers running), and the solution's script exists..."
(cd "$STATE_DIR" && sha256sum app.c lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ -s "$WORK_DIR/cpu-usage.sh" ] || fail "there is no $WORK_DIR/cpu-usage.sh"
keep
echo "  -> OK"

echo "[oracle] the CPU time of bench64071782-app: the right cgroup, no growth while only the other container works, growth by exactly what the worker uses (300 ms, then 150 ms) in nanoseconds, the total since the start..."
verify first
echo "[oracle] a container is started that the script has not seen (another ID, runc's own cgroup path); the script is run for it while it works, and for the first container while only the new one works..."
python3 "$STATE_DIR/lab.py" more "$WORK_DIR" >/dev/null || fail "the lab could not start the third container"
verify second
keep
echo "  -> OK: reading the counters changed nothing (every container runs on with the same processes, in the same cgroup)"

echo "[oracle] ALL CHECKS PASSED: for the first container and for one started later (other ID, other cgroup path) the script names the right cgroup and reports the CPU time of the whole cgroup in nanoseconds: no growth when the container idles, growth by what the worker used when it works, and nothing is stopped, paused or changed."
