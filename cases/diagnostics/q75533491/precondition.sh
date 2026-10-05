#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75533491"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SCRIPT_FILE="$WORK_DIR/get_container_id.sh"

# shellcheck disable=SC1091
. "$STATE_DIR/lib.sh"

echo "[precondition] checking the host uses cgroup v2 only (the case is about cgroup v2)..."
FSTYPE=$(stat -fc %T /sys/fs/cgroup)
if [ "$FSTYPE" != "cgroup2fs" ]; then
    echo "  -> FAIL: /sys/fs/cgroup is '$FSTYPE', not cgroup2fs; this host does not run cgroup v2 only"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking containerd answers on $SOCK and the work dir exists, without the script..."
[ -S "$SOCK" ] || { echo "  -> FAIL: $SOCK is not a socket"; exit 1; }
sudo ctr version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
[ -d "$WORK_DIR" ] || { echo "  -> FAIL: $WORK_DIR does not exist"; exit 1; }
if [ -e "$SCRIPT_FILE" ]; then
    echo "  -> FAIL: $SCRIPT_FILE already exists"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the three containers run in the default namespace, and no other container"
echo "[precondition] of this case exists..."
[ "$(wc -l < "$STATE_DIR/containers")" = 3 ] || { echo "  -> FAIL: setup did not record three containers"; exit 1; }
while read -r style id; do
    if ! sudo ctr -n default tasks ls 2>/dev/null | awk -v n="$id" '$1==n && $3=="RUNNING"' | grep -q .; then
        echo "  -> FAIL: container $id ($style) has no RUNNING task"
        exit 1
    fi
done < "$STATE_DIR/containers"
N=$(sudo ctr -n default containers ls -q "labels.$CASE_ID==1" 2>/dev/null | wc -l)
if [ "$N" != 3 ]; then
    echo "  -> FAIL: $N containers carry this case's label, expected 3"
    exit 1
fi
echo "  -> OK"

# the symptom of the question, seen from inside each container (as an exec'd process, which is
# what the oracle will use): no v1-style devices directory, no ID in the mountinfo
echo "[precondition] checking the symptom inside each container: no /sys/fs/cgroup/devices and the"
echo "[precondition] container ID is not in /proc/self/mountinfo..."
while read -r style id; do
    OUT=$(cexec "$id" 'if [ -e /sys/fs/cgroup/devices ]; then echo devices-dir; fi; if grep -q "'"$id"'" /proc/self/mountinfo; then echo id-in-mountinfo; fi; echo checked') || {
        echo "  -> FAIL: could not run a command inside container $id ($style)"
        exit 1
    }
    if [ "$OUT" != "checked" ]; then
        echo "  -> FAIL: in container $id ($style): $(echo "$OUT" | tr '\n' ' ')"
        exit 1
    fi
done < "$STATE_DIR/containers"
echo "  -> OK"

# case validity: the ID has to be findable from inside, or the task could not be solved by any script
echo "[precondition] checking the container's own ID can be found by a process inside it (the case"
echo "[precondition] must be solvable)..."
while read -r style id; do
    OUT=$(cexec "$id" 'cat /proc/self/cgroup') || { echo "  -> FAIL: could not read /proc/self/cgroup in $id"; exit 1; }
    if ! echo "$OUT" | grep -q "$id"; then
        echo "  -> FAIL: container $id ($style) does not show its ID in /proc/self/cgroup: $OUT"
        exit 1
    fi
done < "$STATE_DIR/containers"
echo "  -> OK"

echo "[precondition] all conditions met."
