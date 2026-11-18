#!/bin/bash
set -e

CASE_ID="bench40403025"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CID="$CASE_ID"

fail() { echo "  -> FAIL: $1"; exit 1; }
st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
field() { sudo runc state "$CID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["'"$1"'"])'; }

echo "[oracle] check 0: the bundle (config.json, /app) is as recorded..."
python3 - "$(sudo cat "$STATE_DIR/state.json" 2>/dev/null)" <<'PYEOF' || fail "config.json or /app of the bundle changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 1: the container $CID is known to runc, its state is running, and it is the SAME instance setup created (same init pid and start time: not deleted and made again)..."
S=$(field status) || fail "runc has no container $CID"
[ "$S" = "running" ] || fail "runc state of $CID is '$S', expected running"
PID=$(field pid)
[ "$PID" = "$(st "d['pid']")" ] || fail "the init pid is $PID, the container made by setup had $(st "d['pid']") (the container was recreated or replaced)"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat" 2>/dev/null)" = "$(st "d['start']")" ] || fail "pid $PID is not the recorded init process"
echo "  -> OK (pid $PID)"

echo "[oracle] check 2: that process is the program of the bundle (/app, the recorded bytes) with this run's nonce in its environment..."
[ "$(sudo cat "/proc/$PID/cmdline" 2>/dev/null | tr '\0' ' ')" = "/app " ] || fail "pid $PID is not /app"
sudo cat "/proc/$PID/exe" 2>/dev/null | sha256sum | grep -q "^$(sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1]+"/state.json")); print([v for k,v in d["files"].items() if k.endswith("/app")][0])' "$STATE_DIR")" || fail "the executable of pid $PID is not the program of the bundle"
sudo grep -qaF "NONCE=$(st "d['nonce']")" "/proc/$PID/environ" 2>/dev/null || fail "the nonce of this run is not in the environment of pid $PID"
echo "  -> OK"

echo "[oracle] check 3: the program is running now: its tick counter in the container's log with this run's nonce increases within 4 s..."
NONCE=$(st "d['nonce']")
T1=$(grep "bench40403025-ok nonce=$NONCE tick=" "$WORK_DIR/container.log" 2>/dev/null | tail -1 | sed 's/.*tick=//')
[ -n "$T1" ] || { sleep 1.5; T1=$(grep "bench40403025-ok nonce=$NONCE tick=" "$WORK_DIR/container.log" 2>/dev/null | tail -1 | sed 's/.*tick=//'); }
[ -n "$T1" ] || fail "the log has no line of the program with this run's nonce"
sleep 2.2
T2=$(grep "bench40403025-ok nonce=$NONCE tick=" "$WORK_DIR/container.log" 2>/dev/null | tail -1 | sed 's/.*tick=//')
[ "$T2" -gt "$T1" ] 2>/dev/null || fail "the tick counter did not move ($T1 -> $T2): the program is not running"
sudo kill -0 "$PID" 2>/dev/null || fail "pid $PID is gone"
echo "  -> OK (tick $T1 -> $T2)"

echo "[oracle] check 4: exactly one runc container was made from the bundle (no other id was run instead)..."
N=$(sudo runc list 2>/dev/null | awk -v b="$WORK_DIR/" 'NR > 1 && index($4, b) == 1' | wc -l)
[ "$N" = "1" ] || fail "expected exactly 1 runc container from the bundle, found $N"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
