#!/bin/bash
set -e

CASE_ID="bench67820679"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
NS="bench67820679"
CONTAINER="bench67820679-app"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
OUT_DIR="$WORK_DIR/out"

CTR="sudo ctr -a $CTD_SOCK"
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] checking the private containerd and the event recorder run and are the ones setup started..."
for f in containerd.id events.id task.id task.pidns host.pidns token ignore_ids; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
alive_same containerd || fail "the recorded containerd is not running"
alive_same events || fail "the event recorder is not running"
echo "  -> OK"

echo "[precondition] checking the container runs in the namespace $NS, its task is RUNNING and is the one"
echo "[precondition] setup started, in its own pid namespace..."
$CTR namespaces ls -q 2>/dev/null | grep -qx "$NS" || fail "the namespace $NS does not exist"
$CTR -n "$NS" containers ls -q 2>/dev/null | grep -qx "$CONTAINER" || fail "the container $CONTAINER is not in the namespace $NS"
read -r TPID TSTART < "$STATE_DIR/task.id"
LINE=$($CTR -n "$NS" tasks ls 2>/dev/null | awk -v n="$CONTAINER" '$1==n')
echo "$LINE" | awk '{exit !($3=="RUNNING" && $2=="'"$TPID"'")}' || fail "the task of $CONTAINER is not RUNNING with pid $TPID: '$LINE'"
[ "$(sudo awk '{print $22}' /proc/$TPID/stat 2>/dev/null)" = "$TSTART" ] || fail "pid $TPID is not the process setup recorded"
[ "$(sudo readlink /proc/$TPID/ns/pid)" = "$(cat "$STATE_DIR/task.pidns")" ] || fail "the pid namespace of the task changed"
[ "$(cat "$STATE_DIR/task.pidns")" != "$(cat "$STATE_DIR/host.pidns")" ] || fail "the task shares the pid namespace of the host"
echo "  -> OK"

echo "[precondition] checking what the engineer sees: nothing in the namespace default, and the first commands fail..."
[ -z "$($CTR -n default containers ls -q 2>/dev/null)" ] && [ -z "$($CTR -n default tasks ls -q 2>/dev/null)" ] \
    || fail "there is a container or a task in the namespace default"
set +e
timeout -k 5 30 $CTR tasks exec -t "$CONTAINER" sh </dev/null >/dev/null 2>&1
RC1=$?
timeout -k 5 30 $CTR tasks exec --exec-id pre-default "$CONTAINER" sh -c id </dev/null >/dev/null 2>&1
RC2=$?
timeout -k 5 30 $CTR -n "$NS" tasks exec "$CONTAINER" sh -c id </dev/null >/dev/null 2>&1
RC3=$?
set -e
[ "$RC1" != 0 ] && [ "$RC2" != 0 ] && [ "$RC3" != 0 ] \
    || fail "the commands of the engineer do not all fail (exit codes $RC1 $RC2 $RC3)"
echo "  -> OK (all three fail)"

echo "[precondition] checking no exec has been made yet and the output directory is empty..."
EXECS=$(python3 - "$STATE_DIR/events.log" "$STATE_DIR/ignore_ids" <<'PYEOF'
import re
import sys

ign = set(open(sys.argv[2]).read().split())
n = 0
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r'/tasks/exec-added \{.*"exec_id":"([^"]+)"', line)
    if m and m.group(1) not in ign:
        n += 1
print(n)
PYEOF
)
[ "$EXECS" = "0" ] || fail "the recorder already holds $EXECS exec(s) of the container"
[ -z "$(ls -A "$OUT_DIR" 2>/dev/null)" ] || fail "the output directory is not empty"
echo "  -> OK"

echo "[precondition] checking the right command works: an exec as the right namespace and exec ID runs"
echo "[precondition] inside the container, as uid 1234, and sees the token of the container..."
PID_EX="pre-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
echo "$PID_EX" >> "$STATE_DIR/ignore_ids"
OUT=$(timeout -k 5 30 $CTR -n "$NS" tasks exec --exec-id "$PID_EX" "$CONTAINER" /bin/sh -c 'id -u; cat /unique.txt' </dev/null 2>/dev/null) \
    || fail "the exec with the namespace and an exec ID failed"
[ "$(echo "$OUT" | sed -n 1p)" = "1234" ] || fail "the exec did not run as uid 1234"
[ "$(echo "$OUT" | sed -n 2p)" = "$(sudo cat "$STATE_DIR/token")" ] || fail "the exec did not see the token of the container"
echo "  -> OK"

echo "[precondition] all conditions met."
