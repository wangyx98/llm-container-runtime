#!/bin/bash
set -e

CASE_ID="bench73176776"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
APP_REF="$CASE_ID.local/app:1"

CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the node's containerd runs, the helpers are as setup copied them, and its CRI answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer on $T_SOCK"
"${CRI[@]}" inspecti "$APP_REF" >/dev/null 2>&1 || fail "the CRI does not know the image $APP_REF"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the target and its neighbor are real CRI containers of one pod, running; the id of the target is in $WORK_DIR/target.id..."
TID=$(cat "$WORK_DIR/target.id" 2>/dev/null) || fail "$WORK_DIR/target.id is missing"
NID=$(cat "$STATE_DIR/neighbor.id" 2>/dev/null) || fail "the neighbor's id is not recorded"
[[ "$TID" =~ ^[0-9a-f]{64}$ && "$NID" =~ ^[0-9a-f]{64}$ && "$TID" != "$NID" ]] || fail "the ids of the containers are not two distinct container ids"
for pair in "target:$TID" "neighbor:$NID"; do
    name=${pair%%:*}; cid=${pair#*:}
    st=$("${CRI[@]}" inspect -o go-template --template '{{.status.state}} {{.status.metadata.name}} {{.status.logPath}}' "$cid" 2>/dev/null) || fail "the CRI does not know the $name container"
    [ "$st" = "CONTAINER_RUNNING $name $WORK_DIR/logs/${name}_0.log" ] || fail "the $name container is not as setup made it: $st"
done
POD=$(cat "$STATE_DIR/pod.id")
[ "$("${CRI[@]}" inspectp -o go-template --template '{{.status.state}}' "$POD" 2>/dev/null)" = SANDBOX_READY ] || fail "the pod is not ready"
echo "  -> OK: target ${TID:0:12} and neighbor ${NID:0:12}, running, log files $WORK_DIR/logs/target_0.log and neighbor_0.log"

echo "[precondition] each CRI log file holds exactly what its container logged, on both streams, and the files are the only place the output is kept..."
python3 - "$WORK_DIR" <<'PYEOF' || fail "a log file does not match what the container was told to log"
import subprocess
import sys

work = sys.argv[1]
for name in ("target", "neighbor"):
    raw = subprocess.run(["sudo", "cat", "%s/logs/%s_0.log" % (work, name)], capture_output=True).stdout
    got = {"stdout": b"", "stderr": b""}
    for line in raw.split(b"\n"):
        if line:
            ts, st, tag, text = (line.split(b" ", 3) + [b""])[:4]
            assert tag == b"F", "a partial record"
            got[st.decode()] += text + b"\n"
    for s in got:
        exp = open("%s/.bench/%s.%s.exp" % (work, name, s), "rb").read()
        assert got[s] == exp and exp, "%s %s differs" % (name, s)
    print("  -> %s: %d stdout and %d stderr messages, in the CRI log format (timestamp, stream, F, text)" % (name, got["stdout"].count(b"\n"), got["stderr"].count(b"\n")))
PYEOF

echo "[precondition] the problem: ctr, the client one has at hand, sees the tasks but has no command that shows their output..."
sudo ctr -a "$T_SOCK" -n k8s.io tasks ls | grep -q "$TID" || fail "ctr does not list the target as a task"
if { ctr help; ctr tasks help; ctr containers help; } 2>&1 | grep -qE '^ +logs([ ,]|$)'; then fail "this ctr has a logs command"; fi
echo "  -> OK: 'ctr tasks ls' lists the target; none of ctr's commands is 'logs'"
[ ! -e "$WORK_DIR/logs.sh" ] || fail "$WORK_DIR/logs.sh exists already"

echo "[precondition] ALL CHECKS PASSED: two real CRI containers log on stdout and stderr into CRI log files; there is no logs.sh and ctr cannot show their output."
