#!/bin/bash
set -e

CASE_ID="bench58370120"
WORK_DIR="/tmp/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SVC="$WORK_DIR/bin/svc"
CONF="$WORK_DIR/conf/server.conf"

fail() { echo "  -> FAIL: $1"; exit 1; }
warnings() { sudo sh -c "cat '$LIB_BASE'/logs/* 2>/dev/null" | grep -c "Unsupported syscall setsockopt(0x[0-9a-f]*,$1," || true; }

echo "[precondition] the bundle, the program, the wrapper and runsc are there and as recorded..."
python3 - "$(sudo cat "$STATE_DIR/state.json" 2>/dev/null)" <<'PYEOF' || fail "a file of the case is missing or changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[precondition] the service's config sends so_priority (with its default value 0) next to tcp_nodelay and port, and the service is not running yet..."
grep -qE '^[[:space:]]*so_priority[[:space:]]*=[[:space:]]*0' "$CONF" || fail "the config has no 'so_priority = 0'"
grep -qE '^[[:space:]]*tcp_nodelay[[:space:]]*=[[:space:]]*true' "$CONF" || fail "the config has no 'tcp_nodelay = true'"
! "$SVC" status >/dev/null 2>&1 || fail "the service is already running"
echo "  -> OK"

echo "[precondition] the symptom: with this config the service starts and answers, and runsc's debug log shows an 'Unsupported syscall setsockopt' for SO_PRIORITY (level 0x1, option 0xc)..."
"$SVC" start >/dev/null 2>&1 || fail "svc start failed"
NONCE=$(sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]+"/state.json"))["nonce"])' "$STATE_DIR")
R=$("$SVC" exec /client 2>/dev/null) || fail "the service does not answer"
echo "$R" | grep -q "^nonce=$NONCE$" || fail "the answer does not carry the nonce of this run"
echo "$R" | grep -q "so_priority=ok" || fail "the service did not send so_priority"
W=$(warnings 0x1,0xc)
[ "$W" -ge 1 ] || fail "no 'Unsupported syscall setsockopt' for SO_PRIORITY in the debug log"
echo "  -> OK ($W warning line(s); the call itself returned ok: the sandbox ignores the option and reports it)"

echo "[precondition] control: a deliberately unsupported call made by the client (TCP_NOTSENT_LOWAT) also shows up in the log, so the log is live..."
"$SVC" exec /client --probe >/dev/null 2>&1 || fail "the probe call failed"
sleep 0.5
[ "$(warnings 0x6,0x19)" -ge 1 ] || fail "the control call is not in the debug log"
echo "  -> OK"

echo "[precondition] stopping the service again (the job starts it)..."
"$SVC" stop >/dev/null 2>&1 || true
! "$SVC" status >/dev/null 2>&1 || fail "the service is still running"
sudo sh -c "rm -rf '$LIB_BASE'/logs/*"
echo "  -> OK"

echo "[precondition] ALL CHECKS PASSED"
