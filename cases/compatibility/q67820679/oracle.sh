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
PROBE="$OUT_DIR/probe.txt"
UID_EXPECTED=1234

CTR="sudo ctr -a $CTD_SOCK"
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }

# The execs of the container that containerd itself reported, from the recorder started by setup
# (topics /tasks/exec-added, /tasks/exec-started and /tasks/exit of the namespace), without the execs of
# the harness. Prints one line per exec: "<exec id> <added> <exit time> <exit status>" (times in seconds
# since the epoch; the exit status is absent from an event when it is 0).
cat > "$STATE_DIR/execs.py" <<'PYEOF'
import calendar
import json
import re
import sys

log, ign_file, ns, cid = sys.argv[1:5]
ign = set(open(ign_file).read().split())
pat = re.compile(r"^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(\.\d+)? \+0000 UTC (\S+) (/tasks/\S+) (\{.*\})\s*$")
ex = {}
for line in open(log, errors="replace"):
    m = pat.match(line)
    if not m or m.group(8) != ns:
        continue
    ts = calendar.timegm(tuple(int(x) for x in m.group(1, 2, 3, 4, 5, 6)) + (0, 0, 0)) + float(m.group(7) or 0)
    topic = m.group(9)
    try:
        ev = json.loads(m.group(10))
    except ValueError:
        continue
    if ev.get("container_id") != cid:
        continue
    if topic == "/tasks/exec-added":
        ex.setdefault(ev["exec_id"], {})["added"] = ts
    elif topic == "/tasks/exit" and ev.get("id") in ex:
        e = ex[ev["id"]]
        e["exit"] = ts
        e["status"] = ev.get("exit_status", 0)
for eid, e in ex.items():
    if eid in ign or "added" not in e:
        continue
    print(eid, "%.6f" % e["added"], "%.6f" % e.get("exit", 0), e.get("status", "none") if "exit" in e else "none")
PYEOF

echo "[oracle] checking the private containerd and the event recorder are still the ones of setup..."
alive_same containerd || fail "the containerd of the setup is not running any more (restarted or replaced?)"
alive_same events || fail "the event recorder of the harness is not running any more"
echo "  -> OK"

echo "[oracle] checking the container is still the one of setup: its task RUNNING, the same process (a"
echo "[oracle] restarted or re-created container proves nothing)..."
read -r TPID TSTART < "$STATE_DIR/task.id"
LINE=$($CTR -n "$NS" tasks ls 2>/dev/null | awk -v n="$CONTAINER" '$1==n')
[ -n "$LINE" ] || fail "the container $CONTAINER has no task in the namespace $NS any more"
echo "$LINE" | awk '{exit !($3=="RUNNING")}' || fail "the task of $CONTAINER is not RUNNING any more: '$LINE'"
echo "$LINE" | awk '{exit !($2=="'"$TPID"'")}' \
    || fail "the task of $CONTAINER is not the one of setup (pid $TPID): it was restarted or replaced"
[ "$(sudo awk '{print $22}' /proc/$TPID/stat 2>/dev/null)" = "$(cut -d' ' -f2 "$STATE_DIR/task.id")" ] \
    || fail "pid $TPID is not the process of setup any more"
echo "  -> OK"

echo "[oracle] checking containerd reports an exec into the container, finished with exit status 0 (an"
echo "[oracle] nsenter or any command run on the host does not make one)..."
EXECS=$(python3 "$STATE_DIR/execs.py" "$STATE_DIR/events.log" "$STATE_DIR/ignore_ids" "$NS" "$CONTAINER")
if [ -z "$EXECS" ]; then
    fail "containerd saw no exec into $CONTAINER in the namespace $NS: nothing ran through 'ctr tasks exec' (a host command, nsenter, another namespace do not count)"
fi
OK_EXECS=$(echo "$EXECS" | awk '$4=="0"')
if [ -z "$OK_EXECS" ]; then
    fail "every exec into $CONTAINER failed (exit statuses: $(echo "$EXECS" | awk '{printf "%s ", $4}'))"
fi
echo "  -> OK ($(echo "$OK_EXECS" | wc -l) successful exec(s))"

echo "[oracle] checking the probe file was written by the exec: it exists, it is one line, and it was"
echo "[oracle] written while one of the successful execs ran..."
[ -f "$PROBE" ] || fail "$PROBE does not exist: the exec did not run /probe.sh"
[ "$(wc -l < "$PROBE")" = "1" ] || fail "$PROBE does not hold exactly one line"
MTIME=$(sudo stat -c '%.9Y' "$PROBE")
echo "$OK_EXECS" | awk -v m="$MTIME" '{ if (m >= $2 - 0.05 && m <= $3 + 0.05) found = 1 } END { exit !found }' \
    || fail "$PROBE was not written during an exec of the container: it was written by something else"
echo "  -> OK"

echo "[oracle] checking what the probe saw: the token of the container, the user of the container, the pid"
echo "[oracle] namespace of the task (not the host's) and the cgroup, compared with a reference exec of the oracle..."
REF="$OUT_DIR/oracle-ref.txt"
timeout -k 5 30 $CTR -n "$NS" tasks exec --exec-id "oracle-ref-$RANDOM$RANDOM" "$CONTAINER" \
    /bin/sh -c "PROBE_OUT=/out/oracle-ref.txt /probe.sh" </dev/null >/dev/null 2>&1 \
    || fail "(oracle) the reference exec into the container failed"
LINE_REF=$(sudo cat "$REF"); sudo rm -f "$REF"
LINE_SOL=$(cat "$PROBE")
TOKEN=$(sudo cat "$STATE_DIR/token")
f() { echo "$1" | tr '|' '\n' | sed -n "$2p"; }          # field N of a probe line
[ "$(f "$LINE_SOL" 1)" = "$TOKEN" ] || fail "the probe did not see the token of the container: '$(f "$LINE_SOL" 1)'"
[ "$(f "$LINE_SOL" 2)" = "uid=$UID_EXPECTED" ] && [ "$(f "$LINE_SOL" 3)" = "gid=$UID_EXPECTED" ] \
    || fail "the exec ran as $(f "$LINE_SOL" 2) $(f "$LINE_SOL" 3), not as the user of the container (uid=$UID_EXPECTED gid=$UID_EXPECTED)"
PIDNS="pidns=$(cat "$STATE_DIR/task.pidns")"
[ "$(f "$LINE_SOL" 4)" = "$PIDNS" ] || fail "the exec is not in the pid namespace of the task: '$(f "$LINE_SOL" 4)', expected '$PIDNS'"
[ "$(f "$LINE_SOL" 4)" != "pidns=$(cat "$STATE_DIR/host.pidns")" ] || fail "the exec ran in the pid namespace of the host"
[ "$(f "$LINE_SOL" 5)" = "$(f "$LINE_REF" 5)" ] || fail "the exec is not in the cgroup of the container: '$(f "$LINE_SOL" 5 | cut -c1-80)'"
NSPID=$(f "$LINE_SOL" 6 | sed 's/^nspid=//')
case "$NSPID" in ''|*[!0-9]*) fail "the probe has no valid pid: '$NSPID'";; esac
[ "$NSPID" -ge 2 ] || fail "the exec is the init process of a pid namespace"
echo "  -> OK"

echo "[oracle] all checks passed."
