#!/bin/bash
set -e

CASE_ID="bench62874903"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
LIB="/var/lib/$CASE_ID"
IMAGE="localhost/$CASE_ID/app:local"

fail() { echo "  -> FAIL: $1"; exit 1; }
st() { sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]+"/state.json"))[sys.argv[2]])' "$STATE_DIR" "$1"; }

echo "[precondition] the handlers' programs, the drop-in, the configs and the image are there and as recorded..."
sudo python3 - "$(sudo cat "$STATE_DIR/state.json" 2>/dev/null)" <<'PYEOF' || fail "a file of the case is missing or changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
sudo crictl inspecti "$IMAGE" 2>/dev/null | grep -q "$(st image_id)" || fail "CRI-O does not hold the case's image"
echo "  -> OK"

echo "[precondition] CRI-O answers and knows the runtime handlers benchrt and benchrt-verify; the job's log is empty and there is no contract.json yet..."
sudo crictl info >/dev/null 2>&1 || fail "CRI-O does not answer"
CFG=$(sudo crio config 2>/dev/null)
echo "$CFG" | grep -q '^\[crio.runtime.runtimes.benchrt\]' || fail "handler benchrt is not registered"
echo "$CFG" | grep -q '^\[crio.runtime.runtimes.benchrt-verify\]' || fail "handler benchrt-verify is not registered"
[ ! -s "$LIB/rt.log" ] || fail "the job's log is not empty"
[ ! -e "$WORK_DIR/contract.json" ] || fail "contract.json exists already"
[ -z "$(sudo crictl pods -q --name "$CASE_ID")" ] || fail "a pod of the case exists already"
echo "  -> OK"

echo "[precondition] the symptom: a lifecycle (runp, create, start, exec, stop, rm, stopp, rmp) through the oracle's own handler is recorded, and the runtime is called with 'exec', a command the OCI runtime command line (create, start, state, kill, delete) does not define..."
V="$STATE_DIR/verify"
sudo sh -c "sed 's/$CASE_ID-pod/$CASE_ID-pre/; s/$CASE_ID-uid/$CASE_ID-pre-uid/' '$WORK_DIR/pod.json' > '$V/pod.json'; sed 's/$CASE_ID-ctr/$CASE_ID-pre-ctr/' '$WORK_DIR/ctr.json' > '$V/ctr.json'"
E=$(mktemp)
why() { echo "  -> FAIL: $1"; echo "     crictl said: $(tr '\n' ' ' < "$E" | cut -c1-600)"; echo "     CRI-O log (last lines): $(sudo journalctl -u crio -n 12 --no-pager 2>/dev/null | cut -c1-300 | tail -8)"; echo "     the runtime's last call: $(sudo tail -n 2 "$V/rt.log" 2>/dev/null | cut -c1-300)"; rm -f "$E"; exit 1; }
P=$(sudo crictl runp --runtime benchrt-verify "$V/pod.json" 2>"$E") || why "runp failed"
C=$(sudo crictl create "$P" "$V/ctr.json" "$V/pod.json" 2>"$E") || why "create failed"
sudo crictl start "$C" >/dev/null 2>"$E" || why "start failed"
OUT=$(sudo crictl exec "$C" /bench-app echo "pre-$(st token)" 2>"$E") || why "exec failed"
[ "$OUT" = "pre-$(st token)" ] || fail "exec printed '$OUT'"
rm -f "$E"
sudo crictl stop "$C" >/dev/null 2>&1; sudo crictl rm "$C" >/dev/null 2>&1; sudo crictl stopp "$P" >/dev/null 2>&1; sudo crictl rmp "$P" >/dev/null 2>&1
CMDS=$(sudo python3 - "$V/rt.log" <<'PYEOF'
import json, sys
seen = set()
for l in open(sys.argv[1]):
    a = json.loads(l)["argv"]; i = 0
    while i < len(a) and a[i].startswith("-"): i += 2 if "=" not in a[i] else 1
    seen.add(a[i])
print(" ".join(sorted(seen)))
PYEOF
)
echo "$CMDS" | grep -qw exec || fail "the recording shows no exec call (commands seen: $CMDS)"
echo "  -> OK (commands CRI-O's monitor called: $CMDS)"

echo "[precondition] resetting the oracle's log; the job's log stays empty..."
sudo rm -f "$V/rt.log" "$V/pod.json" "$V/ctr.json"
[ ! -s "$LIB/rt.log" ] || fail "the job's log is not empty"
[ -z "$(sudo crictl pods -q --name "$CASE_ID")" ] || fail "the check left a pod behind"
echo "  -> OK"

echo "[precondition] ALL CHECKS PASSED"
