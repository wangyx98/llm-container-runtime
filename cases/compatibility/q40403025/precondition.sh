#!/bin/bash
set -e

CASE_ID="bench40403025"
WORK_DIR="/tmp/$CASE_ID"
BUNDLE="$WORK_DIR/bundle"
STATE_DIR="$WORK_DIR/.bench"
CID="$CASE_ID"

fail() { echo "  -> FAIL: $1"; exit 1; }
st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
status() { sudo runc state "$CID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'; }

echo "[precondition] the bundle and the program are there and as recorded..."
python3 - "$(sudo cat "$STATE_DIR/state.json" 2>/dev/null)" <<'PYEOF' || fail "config.json or /app of the bundle is missing or changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[precondition] the container $CID exists in runc's state and is 'created' (not started), and its init process is the recorded one..."
[ "$(status)" = "created" ] || fail "runc state says '$(status)', expected created"
PID=$(sudo runc state "$CID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')
[ "$PID" = "$(st "d['pid']")" ] || fail "the init pid of the container is $PID, setup recorded $(st "d['pid']")"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st "d['start']")" ] || fail "pid $PID is not the recorded init process"
echo "  -> OK (init pid $PID)"

echo "[precondition] nothing has run yet: the container's log has no line of the program, no other runc container of the case exists..."
! grep -q 'bench40403025-ok' "$WORK_DIR/container.log" || fail "the log already has output of the program"
N=$(sudo runc list 2>/dev/null | awk -v b="$WORK_DIR/" 'NR > 1 && index($4, b) == 1' | wc -l)
[ "$N" = "1" ] || fail "expected exactly 1 runc container made from the bundle, found $N"
echo "  -> OK"

echo "[precondition] the command of the thread, 'sudo runc start' without a container id (in the bundle directory), fails and starts nothing..."
OUT=$(cd "$BUNDLE" && sudo runc start 2>&1) && fail "'runc start' without an id exited with 0"
echo "$OUT" | grep -qi 'container-id\|requires\|Incorrect Usage' || fail "'runc start' failed, but not with a usage/argument error: $(echo "$OUT" | head -2)"
[ "$(status)" = "created" ] || fail "the container is '$(status)' after the failed command"
echo "  -> OK ($(echo "$OUT" | head -1))"

echo "[precondition] ALL CHECKS PASSED"
