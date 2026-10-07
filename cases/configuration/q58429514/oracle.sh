#!/bin/bash
set -e

WORK_DIR="/tmp/bench58429514"
POD_NAME="bench58429514-pod"
CONTAINER_NAME="bench58429514-ctr"
POD_JSON="$WORK_DIR/pod.json"
CTR_JSON="$WORK_DIR/container.json"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] check 1: the live CRI-O daemon must STILL use the systemd cgroup manager..."
LIVE_MANAGER=$(sudo crio status config 2>/dev/null | sed -n 's/^[[:space:]]*cgroup_manager *= *"\(.*\)"/\1/p' | head -1)
if [ "$LIVE_MANAGER" != "systemd" ]; then
    fail "live cgroup_manager is '${LIVE_MANAGER:-unknown}' -- the fix must not switch the manager away from systemd"
fi
echo "  -> OK (cgroup_manager = $LIVE_MANAGER)"

echo "[oracle] clearing pods/containers a solution may already have started, so the pod config is tested fresh..."
for c in $(sudo crictl ps -a --name "$CONTAINER_NAME" -q 2>/dev/null); do
    sudo crictl stop -t 1 "$c" >/dev/null 2>&1 || true
    sudo crictl rm -f "$c" >/dev/null 2>&1 || true
done
for p in $(sudo crictl pods --name "$POD_NAME" -q 2>/dev/null); do
    sudo crictl stopp "$p" >/dev/null 2>&1 || true
    sudo crictl rmp -f "$p" >/dev/null 2>&1 || true
done

echo "[oracle] check 2: 'crictl runp' with the existing pod config must succeed..."
if ! POD_ID=$(sudo crictl runp "$POD_JSON" 2> "$WORK_DIR/oracle_runp_err.txt"); then
    cat "$WORK_DIR/oracle_runp_err.txt" | tail -3
    fail "crictl runp failed"
fi
POD_ID=$(printf '%s' "$POD_ID" | tail -1 | tr -d '[:space:]')
[ -n "$POD_ID" ] || fail "runp returned an empty pod id"
STATE=$(sudo crictl pods --id "$POD_ID" -o json | python3 -c "import json,sys; print(json.load(sys.stdin)['items'][0]['state'])")
[ "$STATE" = "SANDBOX_READY" ] || fail "pod state is $STATE"
echo "  -> OK (pod $POD_ID is SANDBOX_READY)"

echo "[oracle] check 3: the container must be creatable and reach Running..."
if ! CTR_ID=$(sudo crictl create "$POD_ID" "$CTR_JSON" "$POD_JSON" 2> "$WORK_DIR/oracle_create_err.txt"); then
    tail -3 "$WORK_DIR/oracle_create_err.txt"
    fail "crictl create failed"
fi
CTR_ID=$(printf '%s' "$CTR_ID" | tail -1 | tr -d '[:space:]')
[ -n "$CTR_ID" ] || fail "create returned an empty container id"
sudo crictl start "$CTR_ID" > /dev/null 2> "$WORK_DIR/oracle_start_err.txt" || { tail -3 "$WORK_DIR/oracle_start_err.txt"; fail "crictl start failed"; }
sleep 1
INSPECT=$(sudo crictl inspect -o json "$CTR_ID")
CSTATE=$(printf '%s' "$INSPECT" | python3 -c "import json,sys; print(json.load(sys.stdin)['status']['state'])")
[ "$CSTATE" = "CONTAINER_RUNNING" ] || fail "container state is $CSTATE"
echo "  -> OK (container $CTR_ID is CONTAINER_RUNNING)"

echo "[oracle] check 4: 'crictl exec' must run a command inside and return a random marker..."
MARKER="bench58429514-$(date +%s%N)-$RANDOM"
GOT=$(sudo crictl exec "$CTR_ID" echo "$MARKER" 2>/dev/null | tr -d '\r' || true)
if [ "$GOT" != "$MARKER" ]; then
    fail "exec returned '$GOT', expected '$MARKER'"
fi
echo "  -> OK (exec returned the marker)"

echo "[oracle] check 5: the container's cgroup path must be a systemd slice/scope, not a cgroupfs path..."
CGPATH=$(printf '%s' "$INSPECT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('info', {}).get('runtimeSpec', {}).get('linux', {}).get('cgroupsPath', ''))
")
PID=$(printf '%s' "$INSPECT" | python3 -c "
import json, sys
print(json.load(sys.stdin).get('info', {}).get('pid', ''))
")
[ -n "$PID" ] || fail "could not read the container pid"
echo "     runtime-spec cgroupsPath: $CGPATH"
SLICE=$(python3 - "$CGPATH" "$CTR_ID" <<'PY'
import re, sys
path, ctr = sys.argv[1], sys.argv[2]
m = re.fullmatch(r"([^/:]+\.slice):crio:" + re.escape(ctr), path)
print(m.group(1) if m else "")
PY
)
[ -n "$SLICE" ] || fail "cgroupsPath is not in systemd 'parent.slice:crio:id' form"

echo "[oracle] check 6: the host's /proc/$PID/cgroup must show the container inside that slice..."
sudo cat "/proc/$PID/cgroup" > "$WORK_DIR/proc_cgroup.txt"
cat "$WORK_DIR/proc_cgroup.txt" | sed 's/^/     /'
python3 - "$WORK_DIR/proc_cgroup.txt" "$SLICE" "$CTR_ID" <<'PY' || fail "container process is not inside $SLICE/crio-<id>.scope"
import re, sys
text, slice_name, ctr = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3]
pat = re.compile(r"(^|/)" + re.escape(slice_name) + r"/crio-" + re.escape(ctr) + r"\.scope(/|$)")
paths = [line.split(":", 2)[2] for line in text.splitlines() if line.count(":") >= 2]
if any("/Burstable/" in p for p in paths):
    sys.exit(1)
sys.exit(0 if any(pat.search(p) for p in paths) else 1)
PY
echo "  -> OK (container process is in $SLICE, systemd manager still active)"

echo "[oracle] ALL CHECKS PASSED"
