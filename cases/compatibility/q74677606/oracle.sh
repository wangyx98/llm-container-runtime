#!/bin/bash
set -e

CASE_ID="bench74677606"
RUN_BASE="/run/$CASE_ID"
A_SOCK="$RUN_BASE/docker/containerd/containerd.sock"    # Docker's containerd
B_SOCK="$RUN_BASE/containerd/containerd.sock"           # the other containerd
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ANSWER="$WORK_DIR/answer.json"

alive_same() {   # $1 = daemon name: still the process recorded by setup (pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}

echo "[oracle] check 1: the three daemons must be the very processes of the setup, and the Docker"
echo "[oracle]          containers must still run as the tasks they were (nothing stopped or restarted)..."
for d in docker-containerd dockerd containerd; do
    alive_same "$d" || { echo "  -> FAIL: the $d of this task was restarted, stopped or replaced"; exit 1; }
done
LIVE=$(sudo ctr -a "$A_SOCK" -n moby tasks ls 2>/dev/null | awk 'NR>1{print $1, $2, $3}' | LC_ALL=C sort)
WANT=$(python3 - "$STATE_DIR/truth.json" <<'PYEOF'
import json, sys
t = json.load(open(sys.argv[1]))
print("\n".join(sorted("%s %s RUNNING" % (t[k]["id"], t[k]["pid"]) for k in ("target", "other"))))
PYEOF
)
[ "$LIVE" = "$WANT" ] || { echo "  -> FAIL: the Docker containers or their tasks changed"; exit 1; }
echo "  -> OK"

echo "[oracle] check 2: Docker itself must not have been asked: no request reached the Docker daemon"
echo "[oracle]          (docker CLI, curl on its socket, ...) since the precondition..."
BASE=$(cat "$STATE_DIR/api.baseline")
CALLS=$(sudo tail -c +"$((BASE + 1))" "$RUN_BASE/dockerd.log" 2>/dev/null \
    | grep -E 'handling [A-Z]+ request|Calling [A-Z]+ ' | grep -v '_ping' || true)
if [ -n "$CALLS" ]; then
    echo "  -> FAIL: the Docker daemon was asked: $(echo "$CALLS" | head -1 | grep -oE '(request-url=|Calling [A-Z]+ )[^ ]+' | head -1)"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: $ANSWER must be a JSON object with namespace, container_id, pid and"
echo "[oracle]          containerd_socket..."
[ -s "$ANSWER" ] || { echo "  -> FAIL: $ANSWER does not exist or is empty"; exit 1; }
python3 - "$ANSWER" "$STATE_DIR/truth.json" "$A_SOCK" "$B_SOCK" <<'PYEOF'
import json
import sys


def fail(msg):
    # stdout, not stderr: the harness shows only the stdout of the oracle
    print(msg)
    sys.exit(1)


answer_path, truth_path, a_sock, b_sock = sys.argv[1:5]
t = json.load(open(truth_path))
try:
    a = json.load(open(answer_path))
except ValueError as e:
    fail("  -> FAIL: the answer is not valid JSON: %s" % e)
if not isinstance(a, dict):
    fail("  -> FAIL: the answer is not a JSON object")
for k in ("namespace", "container_id", "pid", "containerd_socket"):
    if k not in a:
        fail("  -> FAIL: the answer has no key %s" % k)
cid, pid, ns, sock = a["container_id"], a["pid"], a["namespace"], a["containerd_socket"]
if not isinstance(cid, str) or isinstance(pid, bool) or not isinstance(pid, int) \
        or not isinstance(ns, str) or not isinstance(sock, str):
    fail("  -> FAIL: wrong types: container_id, namespace and containerd_socket are strings, pid an integer")
cid = cid.strip().lower()
tgt, oth, dec = t["target"], t["other"], t["decoy"]

# --- the container
if cid != tgt["id"]:
    if cid == dec["id"]:
        fail("  -> FAIL: container_id is the decoy of the other containerd, not a Docker container")
    if cid == oth["id"]:
        fail("  -> FAIL: container_id is the other Docker container, not the one carrying BENCH_NAME=bench74677606-app")
    if len(cid) < 64 and tgt["id"].startswith(cid):
        fail("  -> FAIL: container_id is a short ID (%d characters): the full 64 character ID is required" % len(cid))
    fail("  -> FAIL: container_id does not match the Docker container")

# --- the process
if pid != tgt["pid"]:
    if pid == tgt["shim_pid"]:
        fail("  -> FAIL: pid is the PID of the containerd shim, not of the container's main process (the task)")
    if pid == dec["pid"]:
        fail("  -> FAIL: pid is the PID of the decoy of the other containerd")
    if pid == oth["pid"]:
        fail("  -> FAIL: pid is the PID of the other Docker container")
    fail("  -> FAIL: pid does not match the task of the container")

# --- where it was found
if ns != "moby":
    fail("  -> FAIL: namespace is %r, the Docker containers are in another namespace" % ns)
if sock.replace("unix://", "", 1) != a_sock:
    if sock.replace("unix://", "", 1) == b_sock:
        fail("  -> FAIL: containerd_socket is the socket of the other containerd, not Docker's")
    fail("  -> FAIL: containerd_socket is not the socket of the containerd that runs the Docker containers")
print("  -> OK")
PYEOF
echo "[oracle] all checks passed."
