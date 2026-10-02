#!/bin/bash
set -e

CASE_ID="bench66762671"
RUN_DIR="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
REPORT="$WORK_DIR/report.json"
DOCKER_SOCK="$RUN_DIR/docker.sock"
CONTAINER_NAME="$CASE_ID"

DOCKER="sudo docker -H unix://$DOCKER_SOCK"

echo "[oracle] check 0: Docker, its containerd and the container must be exactly as"
echo "[oracle]          setup left them (the task is look-only)..."
EXPECTED_ID=$(cat "$STATE_DIR/container_id" 2>/dev/null || true)
EXPECTED_SOCK=$(cat "$STATE_DIR/containerd_socket" 2>/dev/null || true)
EXPECTED_NS=$(cat "$STATE_DIR/namespace" 2>/dev/null || true)
if [ -z "$EXPECTED_ID" ] || [ -z "$EXPECTED_SOCK" ] || [ -z "$EXPECTED_NS" ]; then
    echo "  -> FAIL: setup's recorded ground truth is missing"
    exit 1
fi
RUNNING=$($DOCKER inspect -f '{{.Id}} {{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)
if [ "$RUNNING" != "$EXPECTED_ID true" ]; then
    echo "  -> FAIL: the Docker container is not the original one, running ('$RUNNING')"
    exit 1
fi
if ! sudo ctr -a "$EXPECTED_SOCK" -n "$EXPECTED_NS" containers ls -q 2>/dev/null | grep -qxF "$EXPECTED_ID"; then
    echo "  -> FAIL: Docker's containerd no longer lists the container"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: the report must exist and be a JSON object with the four keys"
echo "[oracle]          address, namespace, container_id and ctr_command (all"
echo "[oracle]          non-empty strings)..."
if [ ! -s "$REPORT" ]; then
    echo "  -> FAIL: $REPORT does not exist or is empty"
    exit 1
fi
read_key() {   # $1 = key; prints the string value, or nothing
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = d[sys.argv[2]]
except Exception:
    sys.exit(0)
if isinstance(v, str):
    print(v)
' "$REPORT" "$1"
}
R_ADDR=$(read_key address)
R_NS=$(read_key namespace)
R_ID=$(read_key container_id)
R_CMD=$(read_key ctr_command)
if [ -z "$R_ADDR" ] || [ -z "$R_NS" ] || [ -z "$R_ID" ] || [ -z "$R_CMD" ]; then
    echo "  -> FAIL: $REPORT is not valid JSON with non-empty string values for address, namespace, container_id and ctr_command"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: 'address' must be the socket of the containerd that Docker runs"
echo "[oracle]          on (not the system containerd's)..."
R_ADDR_PATH="${R_ADDR#unix://}"
if [ "$(readlink -f "$R_ADDR_PATH" 2>/dev/null)" != "$(readlink -f "$EXPECTED_SOCK")" ]; then
    echo "  -> FAIL: the report says address '$R_ADDR', Docker's containerd listens on '$EXPECTED_SOCK'"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: 'namespace' must be the containerd namespace that holds the"
echo "[oracle]          container..."
if [ "$R_NS" != "$EXPECTED_NS" ]; then
    echo "  -> FAIL: the report says namespace '$R_NS', the container is in '$EXPECTED_NS'"
    exit 1
fi
echo "  -> OK ($R_NS)"

echo "[oracle] check 4: 'container_id' must be the full ID Docker reports (it differs"
echo "[oracle]          on every run, so it has to be read from the system)..."
if [ "$R_ID" != "$EXPECTED_ID" ]; then
    echo "  -> FAIL: the report says container_id '$R_ID', expected $EXPECTED_ID"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 5: 'ctr_command' must be a ctr command that, run as it stands by"
echo "[oracle]          the current user, lists the container..."
if ! python3 -c '
import re, sys
cmd = sys.argv[1]
ok = re.match(r"^\s*([A-Za-z_]\w*=\S+\s+)*(sudo(\s+-\S+)*\s+)?(env\s+)?([A-Za-z_]\w*=\S+\s+)*(/\S*/)?ctr(\s|$)", cmd)
sys.exit(0 if ok else 1)
' "$R_CMD"; then
    echo "  -> FAIL: ctr_command is not a ctr command: $R_CMD"
    exit 1
fi
CMD_OUT=$(timeout 30 bash -c "$R_CMD" </dev/null 2>&1) || {
    echo "  -> FAIL: running ctr_command failed: $R_CMD"
    echo "$CMD_OUT" | tail -3 | sed 's/^/     /'
    exit 1
}
if ! echo "$CMD_OUT" | grep -qF "$EXPECTED_ID"; then
    echo "  -> FAIL: ctr_command ran but its output does not list the container: $R_CMD"
    exit 1
fi
echo "  -> OK ($R_CMD)"

echo "[oracle] ALL CHECKS PASSED"
