#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
# explicit endpoints: whatever the solution did to /etc/crictl.yaml, grade
# against containerd itself
CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
WORK_DIR="/tmp/bench78814823"
STATE_DIR="$WORK_DIR/.bench"
REPORT="$WORK_DIR/report.json"
IMAGE_REF="docker.io/library/bench78814823-app:latest"

echo "[oracle] check 0: containerd must be up and answering on the CRI..."
sudo systemctl is-active --quiet containerd || { echo "  -> FAIL: containerd is not active"; exit 1; }
$CRICTL info >/dev/null 2>&1 || { echo "  -> FAIL: crictl cannot talk to containerd"; exit 1; }
echo "  -> OK"

echo "[oracle] check 1: the report must exist and be a JSON object with the three"
echo "[oracle]          keys namespace, image_id and ctr_command (all non-empty strings)..."
EXPECTED_ID=$(cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
EXPECTED_NS=$(cat "$STATE_DIR/namespace" 2>/dev/null || true)
if [ -z "$EXPECTED_ID" ] || [ -z "$EXPECTED_NS" ]; then
    echo "  -> FAIL: setup's recorded ground truth is missing"
    exit 1
fi
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
R_NS=$(read_key namespace)
R_ID=$(read_key image_id)
R_CMD=$(read_key ctr_command)
if [ -z "$R_NS" ] || [ -z "$R_ID" ] || [ -z "$R_CMD" ]; then
    echo "  -> FAIL: $REPORT is not valid JSON with non-empty string values for namespace, image_id and ctr_command"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: 'namespace' must be the containerd namespace that really holds"
echo "[oracle]          the image (the one the CRI uses)..."
if [ "$R_NS" != "$EXPECTED_NS" ]; then
    echo "  -> FAIL: the report says namespace '$R_NS', the image is in '$EXPECTED_NS'"
    exit 1
fi
echo "  -> OK ($R_NS)"

echo "[oracle] check 3: 'image_id' must be the full image ID the CRI reports for it"
echo "[oracle]          (it differs on every run, so it has to be read from the system)..."
if [ "${R_ID#sha256:}" != "$EXPECTED_ID" ]; then
    echo "  -> FAIL: the report says image_id '$R_ID', expected $EXPECTED_ID"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 4: 'ctr_command' must be a ctr command that, run as it stands by"
echo "[oracle]          the current user, lists the image..."
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
if ! echo "$CMD_OUT" | grep -qF "$IMAGE_REF"; then
    echo "  -> FAIL: ctr_command ran but its output does not list $IMAGE_REF: $R_CMD"
    exit 1
fi
echo "  -> OK ($R_CMD)"

echo "[oracle] ALL CHECKS PASSED"
