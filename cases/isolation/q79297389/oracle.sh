#!/bin/bash
# Checks the world after the solution: everything is read from the host (/proc, the data dir, runc/ctr state, the wrapper's log).
CASE_ID="bench79297389"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
NS="k8s.io"
CT="$CASE_ID-app"
fail() { echo "[oracle] FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1"; }
UID_APP=$(st uid); GID_APP=$(st gid); PID=$(st pid); TOKEN=$(st token)

echo "[oracle] the workload is untouched: same task, same process, same user, same capabilities..."
sudo ctr -n $NS tasks ls 2>/dev/null | awk -v n="$CT" -v p="$PID" '$1 == n && $2 == p && $3 == "RUNNING"' | grep -q . || fail "task $CT is not RUNNING as pid $PID any more"
[ "$(sudo awk '{print $22}' /proc/$PID/stat)" = "$(st starttime)" ] || fail "pid $PID has another start time: the workload was restarted or replaced"
[ "$(sudo tr '\0' ' ' < /proc/$PID/cmdline 2>/dev/null)" = "/usr/bin/idle " ] || fail "the main process is not /usr/bin/idle"
[ "$(sudo awk '/^Uid:/ {print $2":"$3":"$4":"$5}' /proc/$PID/status)" = "$UID_APP:$UID_APP:$UID_APP:$UID_APP" ] || fail "the main process does not run as uid $UID_APP any more"
[ "$(sudo awk '/^Gid:/ {print $2":"$3":"$4":"$5}' /proc/$PID/status)" = "$GID_APP:$GID_APP:$GID_APP:$GID_APP" ] || fail "the main process does not run as gid $GID_APP any more"
[ "$(sudo grep -E '^(CapEff|CapBnd)' /proc/$PID/status)" = "$(st caps)" ] || fail "the main process has other capabilities than at setup (privileged?)"
sudo sh -c "for n in pid mnt ipc net uts; do echo \"\$n=\$(readlink /proc/$PID/ns/\$n)\"; done" | diff -q - <(sudo cat "$STATE_DIR/ns") >/dev/null || fail "the workload's namespaces changed"
[ "$(sudo readlink /proc/$PID/ns/pid)" != "$(readlink /proc/self/ns/pid)" ] || fail "the workload shares the host's PID namespace"

echo "[oracle] the node debug container, its wrapper and the node's ctr were not changed..."
sudo sh -c "cd '$STATE_DIR' && sha256sum -c --quiet sums" || fail "wrapper, node ctr or debug spec differ from the recorded hashes"
CAPEFF=$(sudo "$WORK_DIR/node-debug" grep '^CapEff' /proc/self/status 2>/dev/null | awk '{print $2}')
[ "$CAPEFF" = "$(st debug_capeff)" ] || fail "the debug container's CapEff is $CAPEFF, not the recorded $(st debug_capeff)"
[ -z "$(sudo runc --root "$STATE_DIR/runc" list -q 2>/dev/null)" ] || fail "a debug container is still around"

echo "[oracle] /data/done was written by a new process of the workload, as root:root..."
[ -f "$DATA_DIR/done" ] || fail "$DATA_DIR/done does not exist"
sudo python3 - "$DATA_DIR/done" "$TOKEN" "$STATE_DIR/ns" "$STATE_DIR/debug.log" <<'PY' || exit 1
import os, sys
done, token, nsfile, log = sys.argv[1:5]
def fail(m): print("[oracle] FAIL: " + m); sys.exit(1)
st = os.stat(done)
if (st.st_uid, st.st_gid) != (0, 0):
    fail("/data/done belongs to %d:%d, not 0:0" % (st.st_uid, st.st_gid))
f = dict(l.split("=", 1) for l in open(done).read().splitlines() if "=" in l)
if f.get("uid") != "0" or f.get("gid") != "0":
    fail("the program ran as uid=%s gid=%s" % (f.get("uid"), f.get("gid")))
if f.get("token") != token:
    fail("wrong token: the result does not come from the image's program")
ns = dict(l.split("=", 1) for l in open(nsfile).read().splitlines())
for k in ("pid", "mnt", "ipc", "net", "uts"):
    if f.get(k) != ns[k]:
        fail("the program ran in %s namespace %s, the workload's is %s" % (k, f.get(k), ns[k]))
# it has to have been written while a run of the wrapper (the debug container) was going on
t = st.st_mtime_ns
ok = False
for line in open(log):
    a = line.split(" ", 3)
    if len(a) >= 3 and int(a[0]) - 50_000_000 <= t <= int(a[1]) + 50_000_000:
        ok = True
if not ok:
    fail("/data/done was not written during a run of node-debug (not started from the debug container)")
print("[oracle] done: uid=0 gid=0, token and all five namespaces match the workload, written inside a node-debug run")
PY
echo "[oracle] PASS"
exit 0
