#!/bin/bash
set -e

CASE_ID="bench72753140"
RUN_BASE="/run/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"
NS="$CASE_ID"
NS_OTHER="$CASE_ID-other"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ANSWER="$WORK_DIR/answer.json"
TRIPWIRE_EPOCH=946684800

# These two checks have to come before anything below runs ctr itself.
echo "[oracle] check 0: ctr, nerdctl and crictl must not have been run by the solution..."
if [ "$(cat "$STATE_DIR/tripwire_ok" 2>/dev/null)" = 1 ]; then
    while read -r b; do
        [ -n "$b" ] || continue
        AT=$(sudo stat -c %X "$b" 2>/dev/null || echo "$TRIPWIRE_EPOCH")
        if [ "$AT" != "$TRIPWIRE_EPOCH" ]; then
            echo "  -> FAIL: $b was run (the task rules out ctr, nerdctl and crictl)"
            exit 1
        fi
    done < "$STATE_DIR/tripwire_bins"
    echo "  -> OK"
else
    echo "  -> skipped (access times are not recorded on this machine)"
fi

echo "[oracle] check 1: grpcurl must have been run by the solution..."
if [ "$(cat "$STATE_DIR/tripwire_ok" 2>/dev/null)" = 1 ]; then
    G=$(cat "$STATE_DIR/tripwire_grpcurl")
    AT=$(sudo stat -c %X "$G" 2>/dev/null || echo "$TRIPWIRE_EPOCH")
    if [ "$AT" = "$TRIPWIRE_EPOCH" ]; then
        echo "  -> FAIL: grpcurl was never run (the task asks for the daemon to be queried with grpcurl)"
        exit 1
    fi
    echo "  -> OK"
else
    echo "  -> skipped (access times are not recorded on this machine)"
fi

CTR="sudo ctr -a $SOCK"

echo "[oracle] check 2: the private containerd must be the same process as before and still hold"
echo "[oracle]          exactly the containers it held, all with a running task..."
if ! sudo kill -0 "$(cat "$RUN_BASE/containerd.pid" 2>/dev/null)" 2>/dev/null || ! $CTR version >/dev/null 2>&1; then
    echo "  -> FAIL: the containerd of this task is not running (it was stopped or replaced)"
    exit 1
fi
LIVE=$(for ns in "$NS" "$NS_OTHER"; do
    for c in $($CTR -n "$ns" containers ls -q 2>/dev/null); do echo "$ns $c"; done
done | LC_ALL=C sort)
if [ "$LIVE" != "$(cat "$STATE_DIR/containers.truth")" ]; then
    echo "  -> FAIL: the containers were changed (created, deleted or moved)"
    exit 1
fi
N=$($CTR -n "$NS" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
M=$($CTR -n "$NS_OTHER" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
if [ "$N" -ne 2 ] || [ "$M" -ne 1 ]; then
    echo "  -> FAIL: the tasks were stopped or changed (running: $N in $NS, $M in $NS_OTHER)"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: $ANSWER must exist and be a JSON array of objects with a string"
echo "[oracle]          container_id, a numeric pid and a string status..."
if ! sudo test -s "$ANSWER"; then
    echo "  -> FAIL: $ANSWER does not exist or is empty"
    exit 1
fi
sudo cat "$ANSWER" > "$STATE_DIR/answer.json"
$CTR -n "$NS" tasks ls 2>/dev/null | awk 'NR>1{print $1, $2, $3}' | LC_ALL=C sort > "$STATE_DIR/truth.tasks"
OTHER_ID=$(awk -v n="$NS_OTHER" '$1==n{print $2}' "$STATE_DIR/containers.truth")
python3 - "$STATE_DIR/answer.json" "$STATE_DIR/truth.tasks" "$OTHER_ID" <<'PYEOF'
import json
import sys

try:
    ans = json.load(open(sys.argv[1]))
except Exception as e:
    print("  -> FAIL: the file is not valid JSON (%s)" % e)
    sys.exit(1)
if not isinstance(ans, list) or not all(isinstance(x, dict) for x in ans):
    print("  -> FAIL: the file must be a JSON array of objects")
    sys.exit(1)
for x in ans:
    cid, pid, st = x.get("container_id"), x.get("pid"), x.get("status")
    if not isinstance(cid, str) or isinstance(pid, bool) or not isinstance(pid, int) or not isinstance(st, str):
        print("  -> FAIL: every object needs a string container_id, a numeric pid and a string status: %r" % x)
        sys.exit(1)
print("  -> OK (%d entries)" % len(ans))

truth = {}
for line in open(sys.argv[2]):
    cid, pid, st = line.split()
    truth[cid] = (int(pid), st)
other = sys.argv[3]
got = {}
for x in ans:
    if x["container_id"] in got:
        print("  -> FAIL: %s is listed twice" % x["container_id"])
        sys.exit(1)
    got[x["container_id"]] = (x["pid"], x["status"].upper())

print("[oracle] check 4: the entries must be exactly the tasks of the namespace as containerd")
print("[oracle]          reports them (asked independently): the IDs, the PIDs and the status...")
if other in got:
    print("  -> FAIL: %s belongs to the other namespace, not to the one asked for" % other)
    sys.exit(1)
missing = sorted(set(truth) - set(got))
extra = sorted(set(got) - set(truth))
if missing or extra:
    if missing:
        print("  -> FAIL: task(s) missing from the answer: %s" % ", ".join(missing))
    if extra:
        print("  -> FAIL: entries that are no task of the namespace: %s" % ", ".join(extra))
    sys.exit(1)
for cid in sorted(truth):
    if got[cid] != truth[cid]:
        print("  -> FAIL: %s: the answer says pid %s status %s, containerd says pid %s status %s"
              % (cid, got[cid][0], got[cid][1], truth[cid][0], truth[cid][1]))
        sys.exit(1)
print("  -> OK (%d tasks, IDs, PIDs and status agree)" % len(truth))
PYEOF
echo "[oracle] all checks passed."
