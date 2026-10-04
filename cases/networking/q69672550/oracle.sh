#!/bin/bash
set -e

CASE_ID="bench69672550"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CONTAINER_NAME="$CASE_ID"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
PORT=5000

echo "[oracle] check 0: containerd must be up and answering..."
if ! sudo ctr version >/dev/null 2>&1; then
    echo "  -> FAIL: containerd does not answer"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: a container named '$CONTAINER_NAME' must exist in the default namespace, made"
echo "[oracle]          from the image, with a RUNNING task..."
# a container made by ctr has the name as its id; one made by `nerdctl run --name` keeps the
# name in the label nerdctl/name and has a hash as its id (found here so that it can be rejected
# below with a clear reason instead of "no such container")
CID=""
IMAGE_OF=""
for c in $(sudo ctr containers ls -q 2>/dev/null); do
    FOUND=$(sudo ctr containers info "$c" 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
info = json.load(sys.stdin)
if info.get("ID") == name or (info.get("Labels") or {}).get("nerdctl/name") == name:
    print(info.get("Image", ""))
else:
    sys.exit(1)' "$CONTAINER_NAME" 2>/dev/null) || continue
    CID="$c"
    IMAGE_OF="$FOUND"
    break
done
if [ -z "$CID" ]; then
    echo "  -> FAIL: no container named '$CONTAINER_NAME' in the default namespace (containers: $(sudo ctr containers ls -q 2>/dev/null | tr '\n' ' '))"
    exit 1
fi
if [ "$IMAGE_OF" != "$IMAGE_REF" ]; then
    echo "  -> FAIL: container '$CONTAINER_NAME' was made from '$IMAGE_OF', expected $IMAGE_REF"
    exit 1
fi
echo "[oracle]          and made with ctr, not with nerdctl (which the task rules out)..."
NERDCTL_LABELS=$(sudo ctr containers info "$CID" 2>/dev/null | python3 -c '
import json, sys
labels = json.load(sys.stdin).get("Labels") or {}
print(" ".join(k for k in labels if k.startswith("nerdctl/")))' 2>/dev/null || true)
if [ -n "$NERDCTL_LABELS" ]; then
    echo "  -> FAIL: container '$CONTAINER_NAME' was made with nerdctl (labels: $NERDCTL_LABELS); the task allows ctr only"
    exit 1
fi
PID=""
for _ in $(seq 1 20); do
    PID=$(sudo ctr tasks ls 2>/dev/null | awk -v n="$CID" '$1==n && $3=="RUNNING" {print $2}')
    [ -n "$PID" ] && break
    sleep 0.5
done
if [ -z "$PID" ]; then
    echo "  -> FAIL: container '$CONTAINER_NAME' has no RUNNING task (tasks: $(sudo ctr tasks ls 2>/dev/null | tr '\n' ' '))"
    exit 1
fi
echo "  -> OK (id $CID, host pid $PID)"

echo "[oracle] check 2: a plain request from the host to http://127.0.0.1:$PORT/ must be answered"
echo "[oracle]          with HTTP 200..."
BODY_FILE="$STATE_DIR/answer.txt"
CODE=""
RC=0
for _ in $(seq 1 20); do
    RC=0
    CODE=$(curl -sS --noproxy '*' --max-time 3 -o "$BODY_FILE" -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>"$STATE_DIR/curl.err") || RC=$?
    [ "$RC" = "0" ] && [ "$CODE" = "200" ] && break
    sleep 0.5
done
if [ "$RC" != "0" ] || [ "$CODE" != "200" ]; then
    echo "  -> FAIL: curl http://127.0.0.1:$PORT/ from the host got no HTTP 200 (curl exit $RC, status '$CODE'): $(tr '\n' ' ' < "$STATE_DIR/curl.err")"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: the answer must come from the server of THAT container: it carries the"
echo "[oracle]          image's token and names the pid namespace of the container's main process..."
TOKEN=$(cat "$STATE_DIR/token")
GOT_TOKEN=$(sed -n 's/^token=//p' "$BODY_FILE" | head -1)
GOT_NS=$(sed -n 's/^pidns=//p' "$BODY_FILE" | head -1)
if [ "$GOT_TOKEN" != "$TOKEN" ]; then
    echo "  -> FAIL: the answer on port $PORT does not carry the token of the image's server (got '${GOT_TOKEN:-nothing}'): something else answers there"
    exit 1
fi
WANT_NS=$(sudo readlink "/proc/$PID/ns/pid")
if [ "$GOT_NS" != "$WANT_NS" ]; then
    echo "  -> FAIL: the answer comes from a process in pid namespace '$GOT_NS', not from container '$CONTAINER_NAME' ($WANT_NS)"
    exit 1
fi
echo "  -> OK (answered from inside $WANT_NS)"

echo "[oracle] ALL CHECKS PASSED"
