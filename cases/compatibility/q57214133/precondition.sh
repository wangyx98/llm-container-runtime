#!/bin/bash
set -e

CASE_ID="bench57214133"
WORK_DIR="/tmp/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SVC="$WORK_DIR/bin/svc"
APP="$WORK_DIR/app"

fail() { echo "  -> FAIL: $1"; exit 1; }
# number of 'Unsupported syscall <name>(' lines in the debug log of the current run of the sandbox
warnings() { sudo sh -c "cat '$LIB_BASE'/logs/* 2>/dev/null" | grep -c "Unsupported syscall $1(" || true; }
st() { sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]+"/state.json"))[sys.argv[2]])' "$STATE_DIR" "$1"; }

echo "[precondition] the site, the client, config.json, the wrapper, node and runsc are there and as recorded..."
python3 - "$(sudo cat "$STATE_DIR/state.json" 2>/dev/null)" <<'PYEOF' || fail "a file of the case is missing or changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[precondition] the application's code publishes the site with fs.copyFileSync, and the service is not running yet..."
grep -q 'fs.copyFileSync' "$APP/server.js" || fail "server.js does not call fs.copyFileSync"
! "$SVC" status >/dev/null 2>&1 || fail "the service is already running"
echo "  -> OK"

echo "[precondition] the symptom: the service starts and serves the site, and runsc's debug log shows 'Unsupported syscall copy_file_range'..."
"$SVC" start >/dev/null 2>&1 || fail "svc start failed"
NONCE=$(st nonce)
R=$("$SVC" client GET / gzip 2>/dev/null) || fail "the service does not answer"
echo "$R" | grep -q "\"nonce\":\"$NONCE\"" || fail "the answer does not carry the nonce of this run"
echo "$R" | grep -q '"encoding":"gzip"' || fail "the gzip variant is not served"
W=$(warnings copy_file_range)
[ "$W" -ge 1 ] || fail "no 'Unsupported syscall copy_file_range' in the debug log"
echo "  -> OK ($W line(s); the copy itself worked: the sandbox reports the call and the library falls back)"

echo "[precondition] stopping the service again (the job starts it)..."
"$SVC" stop >/dev/null 2>&1 || true
! "$SVC" status >/dev/null 2>&1 || fail "the service is still running"
sudo sh -c "rm -rf '$LIB_BASE'/logs/*"
echo "  -> OK"

echo "[precondition] ALL CHECKS PASSED"
