#!/bin/bash
set -e

CASE_ID="bench71557667"
RUN_BASE="/run/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"
NS="openfaas-fn"
FN="$CASE_ID-fn"
FN_OTHER="$CASE_ID-other-fn"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ANSWER="$WORK_DIR/answer.json"

CTR="sudo ctr -a $SOCK"

echo "[oracle] check 1: the private containerd must be the same process as before and still hold"
echo "[oracle]          the two functions as running tasks, with the same main processes..."
if ! sudo kill -0 "$(cat "$RUN_BASE/containerd.pid" 2>/dev/null)" 2>/dev/null || ! $CTR version >/dev/null 2>&1; then
    echo "  -> FAIL: the containerd of this task is not running (it was stopped or replaced)"
    exit 1
fi
LIVE=$($CTR -n "$NS" tasks ls 2>/dev/null | awk 'NR>1 && $3=="RUNNING"{print "'"$NS"'", $1, $2}' | LC_ALL=C sort)
if [ "$LIVE" != "$(cat "$STATE_DIR/containers.truth")" ]; then
    echo "  -> FAIL: the functions were stopped, restarted, deleted or changed"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: $ANSWER must exist and be a JSON object with a string marker, a string"
echo "[oracle]          pid_ns and a numeric inner_pid..."
if ! sudo test -s "$ANSWER"; then
    echo "  -> FAIL: $ANSWER does not exist or is empty"
    exit 1
fi
sudo cat "$ANSWER" > "$STATE_DIR/answer.json"

# the truth, asked independently: the marker of each function as a process inside its container
# reads it, and the PID namespaces of the functions' main processes as the host sees them
MARKER=$($CTR -n "$NS" tasks exec --exec-id "$CASE_ID-oracle-1" "$FN" /bin/cat /run/marker 2>/dev/null) || MARKER=""
MARKER_OTHER=$($CTR -n "$NS" tasks exec --exec-id "$CASE_ID-oracle-2" "$FN_OTHER" /bin/cat /run/marker 2>/dev/null) || MARKER_OTHER=""
P1=$(awk -v f="$FN" '$2==f{print $3}' "$STATE_DIR/containers.truth")
P2=$(awk -v f="$FN_OTHER" '$2==f{print $3}' "$STATE_DIR/containers.truth")
NS1=$(sudo readlink "/proc/$P1/ns/pid"); NS2=$(sudo readlink "/proc/$P2/ns/pid"); HOST_NS=$(readlink /proc/self/ns/pid)
if [ -z "$MARKER" ] || [ -z "$NS1" ]; then
    echo "  -> FAIL: the oracle could not read the truth from the function (marker '$MARKER', namespace '$NS1')"
    exit 1
fi

python3 - "$STATE_DIR/answer.json" "$MARKER" "$MARKER_OTHER" "$NS1" "$NS2" "$HOST_NS" "$FN" "$FN_OTHER" <<'PYEOF'
import json
import sys

path, marker, marker_other, ns_fn, ns_other, ns_host, fn, fn_other = sys.argv[1:9]
try:
    ans = json.load(open(path))
except Exception as e:
    print("  -> FAIL: the file is not valid JSON (%s)" % e)
    sys.exit(1)
if not isinstance(ans, dict):
    print("  -> FAIL: the file must be one JSON object")
    sys.exit(1)
m, ns, pid = ans.get("marker"), ans.get("pid_ns"), ans.get("inner_pid")
if not isinstance(m, str) or not isinstance(ns, str) or isinstance(pid, bool) or not isinstance(pid, int):
    print("  -> FAIL: need a string marker, a string pid_ns and a numeric inner_pid: %r" % ans)
    sys.exit(1)
print("  -> OK")

print("[oracle] check 3: the marker must be the one inside the container of %s..." % fn)
m = m.strip()
if not m:
    print("  -> FAIL: the marker is empty (it only exists inside the container, not on the host's disk)")
    sys.exit(1)
if m == marker_other:
    print("  -> FAIL: that is the marker of %s, not of %s" % (fn_other, fn))
    sys.exit(1)
if m != marker:
    print("  -> FAIL: the marker %r is not the one of %s" % (m, fn))
    sys.exit(1)
print("  -> OK")

print("[oracle] check 4: pid_ns must be the PID namespace of the container of %s: not the host's," % fn)
print("[oracle]          not the other function's...")
ns = ns.strip()
if ns == ns_host:
    print("  -> FAIL: pid_ns is the host's PID namespace: the command ran on the host, not in the container")
    sys.exit(1)
if ns == ns_other:
    print("  -> FAIL: pid_ns is the PID namespace of %s" % fn_other)
    sys.exit(1)
if ns != ns_fn:
    print("  -> FAIL: pid_ns %r is not the PID namespace of %s (%s)" % (ns, fn, ns_fn))
    sys.exit(1)
print("  -> OK")

print("[oracle] check 5: inner_pid must be a process ID as numbered inside the container: a process")
print("[oracle]          other than its main process (1), and a small number...")
if not (2 <= pid <= 999):
    print("  -> FAIL: inner_pid %d is not a process ID of a shell started inside the container (2..999)" % pid)
    sys.exit(1)
print("  -> OK")
PYEOF
echo "[oracle] all checks passed."
