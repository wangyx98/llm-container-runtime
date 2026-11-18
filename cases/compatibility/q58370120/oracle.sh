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
NONCE=$(sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]+"/state.json"))["nonce"])' "$STATE_DIR" 2>/dev/null) || fail "setup's record is missing"

echo "[oracle] check 0: the program, the client, config.json, the wrapper (runsc's flags and its debug log) and runsc are as recorded..."
python3 - "$(sudo cat "$STATE_DIR/state.json")" <<'PYEOF' || fail "a program, the wrapper, config.json or runsc was changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 1: the config keeps port 8080 and tcp_nodelay = true and no longer sends so_priority..."
python3 - "$CONF" <<'PYEOF' || exit 1
import sys
keys = {}
for line in open(sys.argv[1]):
    line = line.split("#", 1)[0]
    if "=" in line:
        k, v = line.split("=", 1)
        keys[k.strip()] = v.strip()
if "so_priority" in keys:
    print("  -> FAIL: the config still has so_priority = %s" % keys["so_priority"]); sys.exit(1)
if keys.get("port") != "8080" or keys.get("tcp_nodelay") != "true":
    print("  -> FAIL: port/tcp_nodelay changed or missing: %r" % keys); sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 2: the service runs now, in the sandbox $CASE_ID of the wrapper..."
"$SVC" status >/dev/null 2>&1 || fail "the sandbox $CASE_ID is not running (svc start was not done, or it was stopped)"
"$SVC" status 2>/dev/null | grep -q '"status": "running"' || fail "the sandbox is not in state running"
echo "  -> OK"

echo "[oracle] check 3: 20 requests through the loopback of the sandbox all get a correct answer: the nonce of this run, a growing request counter, TCP_NODELAY on the connection..."
LAST=0
for i in $(seq 1 20); do
    R=$("$SVC" exec /client 2>/dev/null) || fail "request $i: the client got no answer"
    echo "$R" | head -1 | grep -q '^HTTP/1.1 200' || fail "request $i: not an HTTP 200 answer"
    echo "$R" | grep -q "^nonce=$NONCE$" || fail "request $i: the nonce of this run is missing"
    echo "$R" | grep -q '^nodelay_on_connection=1$' || fail "request $i: TCP_NODELAY is not on the connection (the service's other settings are lost)"
    N=$(echo "$R" | sed -n 's/^request=//p')
    [ "$N" -gt "$LAST" ] 2>/dev/null || fail "request $i: the counter does not grow ($LAST -> $N)"
    LAST=$N
done
CALLS=$(echo "$R" | sed -n 's/^setsockopt_calls=//p')
echo "$CALLS" | grep -q 'tcp_nodelay=ok' || fail "the service made no tcp_nodelay call ($CALLS)"
! echo "$CALLS" | grep -q 'so_priority' || fail "the service still sends so_priority: $CALLS"
echo "  -> OK (counter $LAST; the service made these setsockopt calls: $(echo "$CALLS" | cut -c1-60)...)"

echo "[oracle] check 4: runsc's debug log of this run has no 'Unsupported syscall setsockopt' for SO_PRIORITY..."
W=$(warnings 0x1,0xc)
[ "$W" = "0" ] || fail "$W warning line(s) for SO_PRIORITY in the debug log"
echo "  -> OK"

echo "[oracle] check 5: the log is live and not filtered: a deliberately unsupported call (TCP_NOTSENT_LOWAT) made now by the client appears in it..."
"$SVC" exec /client --probe >/dev/null 2>&1 || fail "the probe call failed"
sleep 0.5
[ "$(warnings 0x6,0x19)" -ge 1 ] || fail "the control call is not in the debug log (the log is off, filtered or not the sandbox's)"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
