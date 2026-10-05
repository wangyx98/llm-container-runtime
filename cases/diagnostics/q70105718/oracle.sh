#!/bin/bash
set -e

CASE_ID="bench70105718"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CONTAINER_NAME="$CASE_ID"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
LOG_FILE="/var/log/$CASE_ID/runc.log"

echo "[oracle] check 0: containerd must be up and answering..."
if ! sudo ctr version >/dev/null 2>&1; then
    echo "  -> FAIL: containerd does not answer"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: a container named '$CONTAINER_NAME' must exist in the default namespace, made"
echo "[oracle]          from the image, with a RUNNING task..."
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
echo "  -> OK (id $CID, host pid of its init process: $PID)"

echo "[oracle] check 2: the file $LOG_FILE must exist and hold something..."
if ! sudo test -e "$LOG_FILE"; then
    echo "  -> FAIL: $LOG_FILE does not exist"
    exit 1
fi
if [ "$(sudo stat -c %s "$LOG_FILE" 2>/dev/null)" = "0" ]; then
    echo "  -> FAIL: $LOG_FILE exists but is empty"
    exit 1
fi
echo "  -> OK ($(sudo wc -l < "$LOG_FILE") lines)"

echo "[oracle] check 3: it must hold runc's debug-level lines of setting up THAT container: the 'nsexec'"
echo "[oracle]          messages of one runc process (its stage-0 start, and the line that forwards the"
echo "[oracle]          stage-2 process, which is the container's init process, with host pid $PID)..."
sudo python3 - "$LOG_FILE" "$PID" <<'PYEOF'
import json
import re
import sys

path, pid = sys.argv[1], sys.argv[2]
lines = [l.strip() for l in open(path, errors="replace").read().splitlines() if l.strip()]

# runc writes JSON lines ({"level":"debug","msg":...}) with --log-format json and logrus text lines
# (time="..." level=debug msg="...") with --log-format text
debug_msgs = []
for line in lines:
    level = msg = None
    if line.startswith("{"):
        try:
            obj = json.loads(line)
            level, msg = obj.get("level"), obj.get("msg")
        except ValueError:
            pass
    else:
        m = re.search(r'level=(\w+) msg="((?:[^"\\]|\\.)*)"', line)
        if m:
            level, msg = m.group(1), m.group(2)
    if level == "debug" and isinstance(msg, str):
        debug_msgs.append(msg)

if not debug_msgs:
    print("  -> FAIL: the file holds no debug-level runc log lines (%d lines, the first one: %r)"
          % (len(lines), lines[0][:100]))
    sys.exit(1)

stage0 = set()
forwards = []
for msg in debug_msgs:
    m = re.match(r"nsexec-0\[(\d+)\]: \S+ nsexec stage-0", msg)
    if m:
        stage0.add(m.group(1))
    m = re.match(r"nsexec-0\[(\d+)\]: forward stage-1 \((\d+)\) and stage-2 \((\d+)\) pids to runc", msg)
    if m:
        forwards.append(m.groups())

if not forwards:
    print("  -> FAIL: %d debug lines, but none of runc setting a container up (no 'forward stage-1 ... stage-2' line)"
          % len(debug_msgs))
    sys.exit(1)

mine = [f for f in forwards if f[2] == pid]
if not mine:
    print("  -> FAIL: runc's debug lines of setting up containers with init pids %s are there, none for this container (pid %s)"
          % (", ".join(sorted({f[2] for f in forwards})), pid))
    sys.exit(1)
if not any(f[0] in stage0 for f in mine):
    print("  -> FAIL: the line for pid %s is there, but without the stage-0 start of the same runc process" % pid)
    sys.exit(1)
print("  -> OK (%d debug lines; runc process %s forwarded stage-2 pid %s)" % (len(debug_msgs), mine[0][0], pid))
PYEOF

echo "[oracle] ALL CHECKS PASSED"
